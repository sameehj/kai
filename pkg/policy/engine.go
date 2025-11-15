package policy

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/sameehj/kai/pkg/types"
	"gopkg.in/yaml.v3"
)

// Engine loads policy configuration and validates package manifests against it.
type Engine struct {
	config PolicyConfig
}

type PolicyConfig struct {
	AllowedPackages     []string        `yaml:"allowed_packages"`
	DeniedPackages      []string        `yaml:"denied_packages"`
	AllowedAttachPoints []string        `yaml:"allowed_attach_points"`
	DeniedAttachPoints  []string        `yaml:"denied_attach_points"`
	AllowedCaps         []string        `yaml:"allowed_capabilities"`
	DeniedCaps          []string        `yaml:"denied_capabilities"`
	RequiredCaps        []string        `yaml:"required_capabilities"`
	Limits              ResourceLimits  `yaml:"limits"`
	Namespace           NamespacePolicy `yaml:"namespace_enforcement"`
	Signature           SignaturePolicy `yaml:"signature_verification"`
	Sandbox             SandboxPolicy   `yaml:"sandbox"`
}

type ResourceLimits struct {
	MaxProgramsPerChain  int `yaml:"max_programs_per_chain"`
	MaxMapMemoryMB       int `yaml:"max_map_memory_mb"`
	MaxEventsPerSec      int `yaml:"max_events_per_sec"`
	MaxProgramSizeBytes  int `yaml:"max_program_size_bytes"`
	MaxAttachNamespaces  int `yaml:"max_attach_namespaces"`
	MaxConcurrentSandbox int `yaml:"max_concurrent_sandboxes"`
}

type NamespacePolicy struct {
	RequireCgroupFilter bool   `yaml:"require_cgroup_filter"`
	DefaultScope        string `yaml:"default_scope"`
}

type SignaturePolicy struct {
	Enabled     bool     `yaml:"enabled"`
	TrustedKeys []string `yaml:"trusted_keys"`
}

type SandboxPolicy struct {
	Enabled             bool `yaml:"enabled"`
	RequireUIDNamespace bool `yaml:"require_uid_namespace"`
	RequireIsolatedBPF  bool `yaml:"require_isolated_bpffs"`
}

// AttachRequest captures the runtime context for policy checks during attachment.
type AttachRequest struct {
	PackageID  string
	Package    *types.Package
	CgroupPath string
	Interface  string
	Sandbox    *types.SandboxInfo
}

// Report summarises policy evaluation results.
type Report struct {
	Package    string   `json:"package"`
	Violations []string `json:"violations"`
	Passed     bool     `json:"passed"`
}

func NewEngine(configPath string) (*Engine, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("read policy config: %w", err)
	}

	var cfg PolicyConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse policy config: %w", err)
	}

	return &Engine{config: cfg}, nil
}

// ValidatePackage enforces manifest-level safety checks.
func (e *Engine) ValidatePackage(pkg *types.Package) error {
	if violations := e.collectPackageViolations(pkg); len(violations) > 0 {
		return errors.New(strings.Join(violations, "; "))
	}
	return nil
}

// ValidateArtifacts enforces filesystem rules such as object size limits.
func (e *Engine) ValidateArtifacts(packagePath string, pkg *types.Package) error {
	if violations := e.collectArtifactViolations(packagePath, pkg); len(violations) > 0 {
		return errors.New(strings.Join(violations, "; "))
	}
	return nil
}

// ValidateAttach ensures runtime attachment obeys namespace and sandbox constraints.
func (e *Engine) ValidateAttach(req AttachRequest) error {
	if violations := e.collectAttachViolations(req); len(violations) > 0 {
		return errors.New(strings.Join(violations, "; "))
	}
	return nil
}

// ReportPackage returns a structured policy report for diagnostics.
func (e *Engine) ReportPackage(packagePath string, pkg *types.Package) Report {
	violations := e.collectPackageViolations(pkg)
	violations = append(violations, e.collectArtifactViolations(packagePath, pkg)...)
	return Report{
		Package:    pkg.Metadata.Name,
		Violations: violations,
		Passed:     len(violations) == 0,
	}
}

func (e *Engine) collectPackageViolations(pkg *types.Package) []string {
	if pkg == nil {
		return []string{"package manifest missing"}
	}

	var violations []string
	if !e.isPackageAllowed(pkg.Metadata.Name) {
		violations = append(violations, fmt.Sprintf("package %s not allowed by policy", pkg.Metadata.Name))
	}
	if e.isPackageDenied(pkg.Metadata.Name) {
		violations = append(violations, fmt.Sprintf("package %s explicitly denied", pkg.Metadata.Name))
	}

	for _, prog := range pkg.Interface.Programs {
		if e.isAttachPointDenied(prog.Type) {
			violations = append(violations, fmt.Sprintf("attach point %s denied by policy", prog.Type))
		} else if !e.isAttachPointAllowed(prog.Type) {
			violations = append(violations, fmt.Sprintf("attach point %s not permitted", prog.Type))
		}
	}

	if limit := e.config.Limits.MaxProgramsPerChain; limit > 0 && len(pkg.Interface.Programs) > limit {
		violations = append(violations, fmt.Sprintf("too many programs (%d > %d)", len(pkg.Interface.Programs), limit))
	}

	if maxMem := e.config.Limits.MaxMapMemoryMB; maxMem > 0 {
		if usage := estimateMapMemory(pkg.Interface.Maps); usage > maxMem*1024*1024 {
			violations = append(violations, fmt.Sprintf("map memory usage %d exceeds %d MB", usage, maxMem))
		}
	}

	if e.config.Namespace.RequireCgroupFilter && !supportsCgroupFilter(pkg.Interface.Parameters) {
		violations = append(violations, "package must expose cgroup filtering parameter")
	}

	if caps := pkg.Requirements.Capabilities; len(caps) > 0 {
		for _, cap := range caps {
			if e.isCapabilityDenied(cap) {
				violations = append(violations, fmt.Sprintf("capability %s denied by policy", cap))
			}
			if len(e.config.AllowedCaps) > 0 && !contains(e.config.AllowedCaps, cap) {
				violations = append(violations, fmt.Sprintf("capability %s not in allowlist", cap))
			}
		}
	}

	for _, required := range e.config.RequiredCaps {
		if !contains(pkg.Requirements.Capabilities, required) {
			violations = append(violations, fmt.Sprintf("capability %s required by policy", required))
		}
	}

	return violations
}

func (e *Engine) collectArtifactViolations(packagePath string, pkg *types.Package) []string {
	if packagePath == "" || pkg == nil {
		return nil
	}
	limit := e.config.Limits.MaxProgramSizeBytes
	if limit <= 0 {
		return nil
	}

	var violations []string
	for _, prog := range pkg.Interface.Programs {
		target := prog.File
		if !filepath.IsAbs(target) {
			target = filepath.Join(packagePath, target)
		}
		info, err := os.Stat(target)
		if err != nil {
			violations = append(violations, fmt.Sprintf("stat program %s: %v", prog.File, err))
			continue
		}
		if size := info.Size(); size > int64(limit) {
			violations = append(violations, fmt.Sprintf("program %s size %d exceeds limit %d bytes", prog.Name, size, limit))
		}
	}
	return violations
}

func (e *Engine) collectAttachViolations(req AttachRequest) []string {
	var violations []string
	if req.Package == nil {
		return append(violations, "package manifest required for attachment validation")
	}

	if e.config.Namespace.RequireCgroupFilter && req.CgroupPath == "" {
		violations = append(violations, "attachment requires cgroup namespace per policy")
	}

	if e.config.Sandbox.Enabled {
		if req.Sandbox == nil {
			violations = append(violations, "sandbox metadata missing for attachment")
		} else {
			if e.config.Sandbox.RequireUIDNamespace && !req.Sandbox.UIDNamespace {
				violations = append(violations, "sandbox must enable UID namespace isolation")
			}
			if e.config.Sandbox.RequireIsolatedBPF && req.Sandbox.BPFFSPath == "" {
				violations = append(violations, "sandbox missing isolated bpffs mount")
			}
		}
	}

	return violations
}

func (e *Engine) isPackageAllowed(name string) bool {
	if len(e.config.AllowedPackages) == 0 {
		return true
	}
	for _, pattern := range e.config.AllowedPackages {
		if matchPattern(pattern, name) {
			return true
		}
	}
	return false
}

func (e *Engine) isPackageDenied(name string) bool {
	for _, pattern := range e.config.DeniedPackages {
		if matchPattern(pattern, name) {
			return true
		}
	}
	return false
}

func (e *Engine) isAttachPointAllowed(kind string) bool {
	if len(e.config.AllowedAttachPoints) == 0 {
		return true
	}
	for _, allowed := range e.config.AllowedAttachPoints {
		if allowed == kind {
			return true
		}
	}
	return false
}

func (e *Engine) isAttachPointDenied(kind string) bool {
	for _, denied := range e.config.DeniedAttachPoints {
		if denied == kind {
			return true
		}
	}
	return false
}

func (e *Engine) isCapabilityDenied(cap string) bool {
	for _, denied := range e.config.DeniedCaps {
		if denied == cap {
			return true
		}
	}
	return false
}

func matchPattern(pattern, value string) bool {
	switch {
	case pattern == "*":
		return true
	case strings.HasSuffix(pattern, "*"):
		prefix := strings.TrimSuffix(pattern, "*")
		return strings.HasPrefix(value, prefix)
	default:
		return pattern == value
	}
}

func supportsCgroupFilter(params []types.ParameterDef) bool {
	for _, param := range params {
		if strings.Contains(param.Name, "cgroup") {
			return true
		}
	}
	return false
}

func estimateMapMemory(maps []types.MapDef) int {
	total := 0
	for _, m := range maps {
		keySize := estimateFieldSize(m.Schema.KeyType)
		valueSize := 0
		if m.Schema.ValueType != "" {
			valueSize = int(estimateFieldSize(m.Schema.ValueType))
		} else {
			for _, field := range m.Schema.Fields {
				valueSize += int(estimateFieldSize(field.Type))
			}
		}
		if valueSize == 0 {
			valueSize = 8
		}
		if keySize == 0 {
			keySize = 4
		}
		total += (int(keySize) + valueSize) * int(m.MaxEntries)
	}
	return total
}

func estimateFieldSize(t string) uint32 {
	switch {
	case t == "u8":
		return 1
	case t == "u16":
		return 2
	case t == "u32":
		return 4
	case t == "u64":
		return 8
	case strings.HasPrefix(t, "char["):
		var n int
		if _, err := fmt.Sscanf(t, "char[%d]", &n); err == nil {
			return uint32(n)
		}
		return 1
	default:
		return 4
	}
}

func contains(list []string, target string) bool {
	for _, item := range list {
		if item == target {
			return true
		}
	}
	return false
}
