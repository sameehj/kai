package policy

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/sameehj/kai/pkg/types"
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
			AllowedCaps:         []string{"CAP_BPF"},
			Limits: ResourceLimits{
				MaxProgramsPerChain: 4,
				MaxMapMemoryMB:      1,
				MaxProgramSizeBytes: 1024,
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
		Requirements: types.Requirements{
			Capabilities: []string{"CAP_BPF"},
		},
	}

	if err := engine.ValidatePackage(pkg); err != nil {
		t.Fatalf("expected package to pass validation, got %v", err)
	}
}

func TestValidateArtifacts(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	obj := filepath.Join(tmp, "prog.o")
	if err := os.WriteFile(obj, bytes.Repeat([]byte{0x0}, 8), 0o644); err != nil {
		t.Fatalf("write temp obj: %v", err)
	}

	engine := &Engine{
		config: PolicyConfig{
			Limits: ResourceLimits{
				MaxProgramSizeBytes: 4,
			},
		},
	}

	pkg := &types.Package{
		Interface: types.Interface{
			Programs: []types.ProgramDef{
				{Name: "demo", File: "prog.o"},
			},
		},
	}

	if err := engine.ValidateArtifacts(tmp, pkg); err == nil {
		t.Fatalf("expected artifact validation to fail due to size limit")
	}
}

func TestValidateAttach(t *testing.T) {
	t.Parallel()

	engine := &Engine{
		config: PolicyConfig{
			Namespace: NamespacePolicy{
				RequireCgroupFilter: true,
			},
			Sandbox: SandboxPolicy{
				Enabled:             true,
				RequireUIDNamespace: true,
				RequireIsolatedBPF:  true,
			},
		},
	}

	err := engine.ValidateAttach(AttachRequest{
		PackageID:  "demo@1.0.0",
		Package:    &types.Package{},
		CgroupPath: "",
		Sandbox:    nil,
	})
	if err == nil {
		t.Fatalf("expected attach validation to fail without sandbox/cgroup")
	}

	req := AttachRequest{
		PackageID:  "demo@1.0.0",
		Package:    &types.Package{},
		CgroupPath: "/sys/fs/cgroup/demo",
		Sandbox: &types.SandboxInfo{
			UIDNamespace: true,
			BPFFSPath:    "/tmp/bpf",
		},
	}
	if err := engine.ValidateAttach(req); err != nil {
		t.Fatalf("expected attach validation to pass, got %v", err)
	}
}

func TestReportPackage(t *testing.T) {
	t.Parallel()

	engine := &Engine{
		config: PolicyConfig{
			AllowedPackages: []string{"demo"},
			Limits: ResourceLimits{
				MaxProgramSizeBytes: 4,
			},
		},
	}

	tmp := t.TempDir()
	obj := filepath.Join(tmp, "prog.o")
	if err := os.WriteFile(obj, bytes.Repeat([]byte{0x1}, 8), 0o644); err != nil {
		t.Fatalf("write obj: %v", err)
	}

	pkg := &types.Package{
		Metadata: types.Metadata{
			Name: "demo",
		},
		Interface: types.Interface{
			Programs: []types.ProgramDef{
				{Name: "demo", File: "prog.o"},
			},
		},
	}

	report := engine.ReportPackage(tmp, pkg)
	if report.Passed || len(report.Violations) == 0 {
		t.Fatalf("expected violations to be reported")
	}
}
