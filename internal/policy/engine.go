package policy

import (
	"fmt"
	"os"
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
	AllowedAttachPoints []string        `yaml:"allowed_attach_points"`
	DeniedAttachPoints  []string        `yaml:"denied_attach_points"`
	RequiredCaps        []string        `yaml:"required_capabilities"`
	Limits              ResourceLimits  `yaml:"limits"`
	Namespace           NamespacePolicy `yaml:"namespace_enforcement"`
	Signature           SignaturePolicy `yaml:"signature_verification"`
}

type ResourceLimits struct {
	MaxProgramsPerChain int `yaml:"max_programs_per_chain"`
	MaxMapMemoryMB      int `yaml:"max_map_memory_mb"`
	MaxEventsPerSec     int `yaml:"max_events_per_sec"`
}

type NamespacePolicy struct {
	RequireCgroupFilter bool   `yaml:"require_cgroup_filter"`
	DefaultScope        string `yaml:"default_scope"`
}

type SignaturePolicy struct {
	Enabled     bool     `yaml:"enabled"`
	TrustedKeys []string `yaml:"trusted_keys"`
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

// ValidatePackage enforces a coarse set of safety checks.
func (e *Engine) ValidatePackage(pkg *types.Package) error {
	if !e.isPackageAllowed(pkg.Metadata.Name) {
		return fmt.Errorf("package %s not allowed by policy", pkg.Metadata.Name)
	}

	for _, prog := range pkg.Interface.Programs {
		if e.isAttachPointDenied(prog.Type) {
			return fmt.Errorf("attach point %s denied by policy", prog.Type)
		}
		if !e.isAttachPointAllowed(prog.Type) {
			return fmt.Errorf("attach point %s not permitted", prog.Type)
		}
	}

	if limit := e.config.Limits.MaxProgramsPerChain; limit > 0 && len(pkg.Interface.Programs) > limit {
		return fmt.Errorf("too many programs (%d > %d)", len(pkg.Interface.Programs), limit)
	}

	if maxMem := e.config.Limits.MaxMapMemoryMB; maxMem > 0 {
		if usage := estimateMapMemory(pkg.Interface.Maps); usage > maxMem*1024*1024 {
			return fmt.Errorf("map memory usage %d exceeds %d MB", usage, maxMem)
		}
	}

	if e.config.Namespace.RequireCgroupFilter && !supportsCgroupFilter(pkg.Interface.Parameters) {
		return fmt.Errorf("package must expose cgroup filtering parameter")
	}

	return nil
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
