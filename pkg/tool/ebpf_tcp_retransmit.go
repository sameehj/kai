package tool

import (
	"context"
	"fmt"
	"time"

	"github.com/sameehj/kai/pkg/ebpf"
)

type EBPFTCPRetransmitTool struct{}

func (t *EBPFTCPRetransmitTool) Name() string { return "ebpf_tcp_retransmit" }

func (t *EBPFTCPRetransmitTool) Description() string {
	return "Check eBPF readiness for TCP retransmit tracing and validate duration input"
}

func (t *EBPFTCPRetransmitTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"duration": map[string]interface{}{
				"type":        "string",
				"description": "How long to monitor (e.g., '10s', '1m')",
				"default":     "10s",
			},
		},
	}
}

func (t *EBPFTCPRetransmitTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	_ = ctx
	dur := "10s"
	if v, ok := input["duration"].(string); ok && v != "" {
		dur = v
	}
	if _, err := time.ParseDuration(dur); err != nil {
		return "", fmt.Errorf("invalid duration %q: %w", dur, err)
	}

	mgr, err := ebpf.NewManager()
	if err != nil {
		return "", err
	}
	if err := mgr.CheckRequirements(); err != nil {
		return fmt.Sprintf("eBPF unavailable: %v", err), nil
	}
	return fmt.Sprintf("eBPF environment ready. Duration accepted: %s. Next step: run the tcp-retransmit skill loader on Linux.", dur), nil
}
