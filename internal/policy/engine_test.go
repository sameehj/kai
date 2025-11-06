package policy

import (
	"testing"

	"github.com/yourusername/kai/pkg/types"
)

func TestMatchPattern(t *testing.T) {
	t.Parallel()

	cases := []struct {
		pattern string
		value   string
		want    bool
	}{
		{"*", "anything", true},
		{"falco-*", "falco-syscalls", true},
		{"falco-*", "tracee-syscalls", false},
		{"tracee", "tracee", true},
	}

	for _, tc := range cases {
		if got := matchPattern(tc.pattern, tc.value); got != tc.want {
			t.Errorf("matchPattern(%q, %q) = %v, want %v", tc.pattern, tc.value, got, tc.want)
		}
	}
}

func TestSupportsCgroupFilter(t *testing.T) {
	t.Parallel()

	params := []types.ParameterDef{
		{Name: "filter_by_cgroup"},
	}
	if !supportsCgroupFilter(params) {
		t.Fatalf("expected parameter list to satisfy cgroup filtering")
	}

	if supportsCgroupFilter(nil) {
		t.Fatalf("nil parameters should not satisfy cgroup filtering requirement")
	}
}

func TestEstimateMapMemory(t *testing.T) {
	t.Parallel()

	maps := []types.MapDef{
		{
			MaxEntries: 2,
			Schema: types.SchemaDef{
				KeyType:   "u32",
				ValueType: "u64",
			},
		},
	}

	if usage := estimateMapMemory(maps); usage == 0 {
		t.Fatalf("expected non-zero memory usage estimation")
	}
}

func TestValidatePackage(t *testing.T) {
	t.Parallel()

	engine := &Engine{
		config: PolicyConfig{
			AllowedPackages:     []string{"falco-*"},
			AllowedAttachPoints: []string{"kprobe"},
			Limits: ResourceLimits{
				MaxProgramsPerChain: 4,
				MaxMapMemoryMB:      1,
			},
			Namespace: NamespacePolicy{
				RequireCgroupFilter: true,
			},
		},
	}

	pkg := &types.Package{
		Metadata: types.Metadata{
			Name: "falco-syscalls",
		},
		Interface: types.Interface{
			Programs: []types.ProgramDef{
				{Type: "kprobe"},
			},
			Maps: []types.MapDef{
				{
					MaxEntries: 1,
					Schema: types.SchemaDef{
						KeyType:   "u32",
						ValueType: "u32",
					},
				},
			},
			Parameters: []types.ParameterDef{
				{Name: "filter_by_cgroup"},
			},
		},
	}

	if err := engine.ValidatePackage(pkg); err != nil {
		t.Fatalf("expected package to pass validation, got %v", err)
	}
}
