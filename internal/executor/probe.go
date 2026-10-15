package executor

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

type TargetSpec struct {
	Type      string
	Host      string
	Port      int
	User      string
	KeyFile   string
	Container string
}

type ProbeResult struct {
	Name        string            `json:"name,omitempty"`
	TargetType  string            `json:"target_type"`
	OS          string            `json:"os"`
	Distro      string            `json:"distro"`
	Kernel      string            `json:"kernel"`
	Arch        string            `json:"arch"`
	HasRoot     bool              `json:"has_root"`
	CPUCores    int               `json:"cpu_cores"`
	MemoryTotal string            `json:"memory_total"`
	EBPFStatus  string            `json:"ebpf_status"`
	Binaries    map[string]bool   `json:"binaries"`
	Missing     []string          `json:"missing,omitempty"`
	Raw         map[string]string `json:"raw"`
}

var defaultProbeBins = []string{"bpftrace", "perf", "ss", "iostat", "mpstat", "pidstat", "journalctl", "docker", "kubectl", "git", "vmstat", "ip"}

func BuildExecutor(spec TargetSpec) (Executor, error) {
	t := strings.ToLower(strings.TrimSpace(spec.Type))
	switch t {
	case "", "local":
		return NewLocalExecutor(), nil
	case "ssh":
		return NewSSHExecutor(SSHConfig{Host: spec.Host, Port: spec.Port, User: spec.User, PrivateKeyPath: spec.KeyFile})
	case "docker":
		return NewDockerExecutor(spec.Container)
	default:
		return nil, fmt.Errorf("unknown target type: %s", spec.Type)
	}
}

func Probe(ctx context.Context, ex Executor) (*ProbeResult, error) {
	probe := &ProbeResult{TargetType: ex.Kind(), Binaries: map[string]bool{}, Raw: map[string]string{}, EBPFStatus: "unknown"}

	uname, err := ex.Run(ctx, []string{"sh", "-lc", "uname -srm"})
	if err == nil {
		probe.Raw["uname"] = strings.TrimSpace(uname.Stdout)
		parts := strings.Fields(strings.TrimSpace(uname.Stdout))
		if len(parts) >= 1 {
			probe.OS = parts[0]
		}
		if len(parts) >= 2 {
			probe.Kernel = parts[1]
		}
		if len(parts) >= 3 {
			probe.Arch = parts[2]
		}
	}

	distro, _ := ex.Run(ctx, []string{"sh", "-lc", "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME=' | cut -d= -f2-"})
	probe.Distro = strings.Trim(strings.TrimSpace(distro.Stdout), "\"")
	probe.Raw["distro"] = probe.Distro

	root, _ := ex.Run(ctx, []string{"sh", "-lc", "id -u"})
	probe.HasRoot = strings.TrimSpace(root.Stdout) == "0"

	cpus, _ := ex.Run(ctx, []string{"sh", "-lc", "nproc 2>/dev/null || getconf _NPROCESSORS_ONLN"})
	probe.CPUCores, _ = strconv.Atoi(strings.TrimSpace(cpus.Stdout))

	mem, _ := ex.Run(ctx, []string{"sh", "-lc", "awk '/MemTotal/ {print $2 \" kB\"}' /proc/meminfo 2>/dev/null"})
	probe.MemoryTotal = strings.TrimSpace(mem.Stdout)

	for _, bin := range defaultProbeBins {
		res, _ := ex.Run(ctx, []string{"sh", "-lc", "command -v " + bin + " >/dev/null 2>&1"})
		ok := res.ExitCode == 0
		probe.Binaries[bin] = ok
		if !ok {
			probe.Missing = append(probe.Missing, bin)
		}
	}

	if probe.Binaries["bpftrace"] {
		probe.EBPFStatus = "supported"
	} else {
		probe.EBPFStatus = "bpftrace missing (optional)"
	}

	return probe, nil
}

func (p *ProbeResult) String() string {
	b, _ := json.MarshalIndent(p, "", "  ")
	return string(b)
}
