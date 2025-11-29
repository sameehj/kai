package tetragon

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/sameehj/kai/pkg/types"
)

// Backend implements the Tetragon CLI integration.
type Backend struct{}

// NewBackend constructs a Tetragon backend.
func NewBackend() *Backend {
	return &Backend{}
}

// RunSensor returns recent security events from Tetragon via the tetra CLI.
func (b *Backend) RunSensor(ctx context.Context, sensor *types.Sensor, params map[string]interface{}) (interface{}, error) {
	if sensor.Spec.Backend != "tetragon" {
		return nil, fmt.Errorf("sensor backend mismatch")
	}

	lookback := "30m"
	if lb, ok := params["lookback"].(string); ok && lb != "" {
		lookback = lb
	}

	cmd := exec.CommandContext(ctx, "tetra", "getevents",
		"--output", "json",
		"--since", lookback,
	)

	if pod, ok := params["pod"].(string); ok && pod != "" {
		cmd.Args = append(cmd.Args, "--pod", pod)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("tetra command failed: %w\nOutput: %s", err, string(output))
	}

	var events []TetragonEvent
	for _, line := range splitLines(string(output)) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		var event TetragonEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			continue
		}
		events = append(events, event)
	}

	var (
		execEvents    int
		fileEvents    int
		networkEvents int
		suspicious    []string
	)

	for _, event := range events {
		if event.ProcessExec != nil && event.ProcessExec.Process != nil {
			execEvents++
			if isSuspicious(event.ProcessExec.Process.Binary) {
				suspicious = append(suspicious,
					fmt.Sprintf("Suspicious exec: %s", event.ProcessExec.Process.Binary))
			}
		}

		if event.ProcessExit != nil {
			fileEvents++
		}

		if event.NetworkEvent != nil {
			networkEvents++
		}
	}

	maxEvents := min(100, len(events))

	return map[string]interface{}{
		"sensor_id":      sensor.Metadata.ID,
		"sensor_name":    sensor.Metadata.Name,
		"backend":        "tetragon",
		"timestamp":      time.Now().Unix(),
		"lookback":       lookback,
		"total_events":   len(events),
		"exec_events":    execEvents,
		"file_events":    fileEvents,
		"network_events": networkEvents,
		"suspicious":     suspicious,
		"events":         events[:maxEvents],
		"success":        true,
	}, nil
}

// TetragonEvent captures the subset of event fields we currently care about.
type TetragonEvent struct {
	ProcessExec  *ProcessExec  `json:"process_exec,omitempty"`
	ProcessExit  *ProcessExit  `json:"process_exit,omitempty"`
	NetworkEvent *NetworkEvent `json:"network,omitempty"`
}

type ProcessExec struct {
	Process *Process `json:"process"`
}

type ProcessExit struct {
	Process *Process `json:"process"`
}

type NetworkEvent struct {
	Protocol string `json:"protocol"`
}

type Process struct {
	Binary string   `json:"binary"`
	Args   []string `json:"arguments"`
	PID    uint32   `json:"pid"`
}

func isSuspicious(binary string) bool {
	suspicious := []string{
		"/bin/bash", "/bin/sh",
		"curl", "wget",
		"nc", "ncat",
		"python", "perl",
	}

	for _, s := range suspicious {
		if contains(binary, s) {
			return true
		}
	}
	return false
}

func splitLines(s string) []string {
	return strings.Split(s, "\n")
}

func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
