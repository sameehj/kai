package kcp

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/sameehj/kai/pkg/types"
)

// Feature describes a detected kernel capability.
type Feature struct {
	Name      string `json:"name"`
	Supported bool   `json:"supported"`
	Details   string `json:"details,omitempty"`
}

// Profile captures kernel characteristics relevant to eBPF packages.
type Profile struct {
	Version          string             `json:"version"`
	Features         map[string]Feature `json:"features"`
	Helpers          map[string]bool    `json:"helpers"`
	BTFPaths         []string           `json:"btf_paths"`
	UnprivilegedBPF  bool               `json:"unprivileged_bpf"`
	VerifierMaxInsn  int                `json:"verifier_max_insn"`
	VerifierLogLevel string             `json:"verifier_log_level"`
}

// Detect gathers a best-effort profile of the running kernel.
func Detect() (*Profile, error) {
	version, err := readKernelVersion()
	if err != nil {
		return nil, fmt.Errorf("read kernel version: %w", err)
	}

	profile := &Profile{
		Version:  version,
		Features: make(map[string]Feature),
		Helpers:  make(map[string]bool),
	}

	profile.detectBTF()
	profile.detectTracing()
	profile.detectRingbuf()
	profile.detectCgroupAttach()
	profile.detectHelpers()
	profile.detectUnprivilegedState()
	return profile, nil
}

// Verify ensures manifest requirements align with the detected kernel capabilities.
func (p *Profile) Verify(req types.Requirements) error {
	if req.Kernel.MinVersion != "" && !kernelVersionGTE(p.Version, req.Kernel.MinVersion) {
		return fmt.Errorf("kernel version %s does not meet requirement %s", p.Version, req.Kernel.MinVersion)
	}

	for _, feature := range req.Kernel.Features {
		if !p.FeatureSupported(feature) {
			return fmt.Errorf("missing kernel feature: %s", feature)
		}
	}

	for _, helper := range req.Kernel.Helpers {
		if !p.Helpers[helper] {
			return fmt.Errorf("missing helper: %s", helper)
		}
	}

	return nil
}

// FeatureSupported returns whether the named capability is available.
func (p *Profile) FeatureSupported(name string) bool {
	if p == nil {
		return false
	}
	if feature, ok := p.Features[name]; ok {
		return feature.Supported
	}
	return false
}

func (p *Profile) setFeature(name string, supported bool, details string) {
	if p.Features == nil {
		p.Features = make(map[string]Feature)
	}
	p.Features[name] = Feature{Name: name, Supported: supported, Details: details}
}

func (p *Profile) detectBTF() {
	searchPaths := []string{
		"/sys/kernel/btf/vmlinux",
		"/boot/vmlinux",
		"/usr/lib/modules/vmlinux",
	}
	found := make([]string, 0, len(searchPaths))
	for _, path := range searchPaths {
		if _, err := os.Stat(path); err == nil {
			found = append(found, path)
		}
	}
	if len(found) > 0 {
		p.BTFPaths = found
	}
	p.setFeature("btf", len(found) > 0, strings.Join(found, ","))
	p.setFeature("core", len(found) > 0, "requires BTF")
}

func (p *Profile) detectRingbuf() {
	supported := kernelVersionGTE(p.Version, "5.8")
	p.setFeature("ringbuf", supported, "requires kernel >= 5.8")
	if supported {
		p.Helpers["bpf_ringbuf_reserve"] = true
	}
}

func (p *Profile) detectTracing() {
	tracefs := "/sys/kernel/tracing"
	if _, err := os.Stat(tracefs); os.IsNotExist(err) {
		tracefs = "/sys/kernel/debug/tracing"
	}
	p.setFeature("tracefs", pathExists(tracefs), tracefs)
}

func (p *Profile) detectCgroupAttach() {
	supported := kernelVersionGTE(p.Version, "4.10")
	p.setFeature("cgroup_skb", supported, "requires kernel >= 4.10")
}

func (p *Profile) detectHelpers() {
	// Conservative baseline helpers.
	p.Helpers["bpf_get_current_task"] = true
	p.Helpers["bpf_probe_read_kernel"] = kernelVersionGTE(p.Version, "5.5")
	p.Helpers["bpf_map_lookup_elem"] = true
	p.Helpers["bpf_tail_call"] = true
}

func (p *Profile) detectUnprivilegedState() {
	data, err := os.ReadFile("/proc/sys/kernel/unprivileged_bpf_disabled")
	if err != nil {
		return
	}
	value := strings.TrimSpace(string(data))
	p.UnprivilegedBPF = value == "0"
}

func readKernelVersion() (string, error) {
	candidates := []string{
		"/proc/sys/kernel/osrelease",
		"/proc/version",
	}
	for _, path := range candidates {
		if data, err := os.ReadFile(path); err == nil {
			return parseVersionString(string(data)), nil
		}
	}
	if output, err := exec.Command("uname", "-r").Output(); err == nil {
		return strings.TrimSpace(string(output)), nil
	}
	return "", fmt.Errorf("kernel version not discoverable")
}

func parseVersionString(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "0.0.0"
	}
	parts := strings.Fields(raw)
	if len(parts) > 0 {
		return parts[0]
	}
	return raw
}

func pathExists(path string) bool {
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
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
