package loader

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/sameehj/kai/pkg/types"
)

// KernelProfile captures basic kernel capabilities detected at runtime.
type KernelProfile struct {
	Version  string
	Features map[string]bool
	Helpers  map[string]bool
}

// DetectKernelProfile gathers a minimal capability matrix for the running kernel.
func DetectKernelProfile() (*KernelProfile, error) {
	kcp := &KernelProfile{
		Features: make(map[string]bool),
		Helpers:  make(map[string]bool),
	}

	data, err := os.ReadFile("/proc/version")
	if err != nil {
		return nil, fmt.Errorf("read kernel version: %w", err)
	}

	parts := strings.Fields(string(data))
	if len(parts) >= 3 {
		kcp.Version = parts[2]
	}

	if _, err := os.Stat("/sys/kernel/btf/vmlinux"); err == nil {
		kcp.Features["BTF"] = true
		kcp.Features["CO-RE"] = true
	}

	// Conservative helper assumptions; in production we would probe.
	kcp.Helpers["bpf_get_current_task"] = true
	kcp.Helpers["bpf_probe_read_kernel"] = true
	kcp.Helpers["bpf_ringbuf_reserve"] = kernelVersionGTE(kcp.Version, "5.8")
	kcp.Helpers["bpf_loop"] = kernelVersionGTE(kcp.Version, "5.17")

	return kcp, nil
}

// Verify ensures the runtime satisfies manifest requirements.
func (kcp *KernelProfile) Verify(req types.Requirements) error {
	if req.Kernel.MinVersion != "" && !kernelVersionGTE(kcp.Version, req.Kernel.MinVersion) {
		return fmt.Errorf("kernel version %s does not meet requirement %s", kcp.Version, req.Kernel.MinVersion)
	}

	for _, feature := range req.Kernel.Features {
		if !kcp.Features[feature] {
			return fmt.Errorf("missing kernel feature: %s", feature)
		}
	}

	for _, helper := range req.Kernel.Helpers {
		if !kcp.Helpers[helper] {
			return fmt.Errorf("missing helper: %s", helper)
		}
	}

	return nil
}

func kernelVersionGTE(current, required string) bool {
	if required == "" {
		return true
	}
	cv := parseVersion(current)
	rv := parseVersion(required)

	for i := 0; i < len(cv) && i < len(rv); i++ {
		if cv[i] > rv[i] {
			return true
		}
		if cv[i] < rv[i] {
			return false
		}
	}
	return len(cv) >= len(rv)
}

func parseVersion(v string) []int {
	v = strings.TrimSpace(v)
	if v == "" {
		return []int{0, 0, 0}
	}

	base := strings.SplitN(v, "-", 2)[0]
	chunks := strings.Split(base, ".")
	out := make([]int, 3)

	for i := 0; i < len(chunks) && i < 3; i++ {
		n, err := strconv.Atoi(chunks[i])
		if err != nil {
			out[i] = 0
			continue
		}
		out[i] = n
	}
	return out
}
