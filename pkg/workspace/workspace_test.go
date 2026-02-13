package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveUsesEnv(t *testing.T) {
	t.Logf("Resolve should use KAI_WORKSPACE")
	dir := t.TempDir()
	t.Setenv("KAI_WORKSPACE", dir)
	if got := Resolve(); got != dir {
		t.Fatalf("expected %q, got %q", dir, got)
	}
}

func TestLoadPromptComponentsAndCompose(t *testing.T) {
	t.Logf("load prompt components and compose output")
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, AgentsFile), []byte("# Base"), 0o644); err != nil {
		t.Fatalf("write agents: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, SoulFile), []byte("Soul text"), 0o644); err != nil {
		t.Fatalf("write soul: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ToolsFile), []byte("Tool usage"), 0o644); err != nil {
		t.Fatalf("write tools: %v", err)
	}
	skillDir := filepath.Join(dir, SkillsDir, "docker")
	if err := os.MkdirAll(skillDir, 0o755); err != nil {
		t.Fatalf("mkdir skills: %v", err)
	}
	if err := os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte("Docker skill"), 0o644); err != nil {
		t.Fatalf("write skill: %v", err)
	}

	pc, err := LoadPromptComponents(dir, []string{"docker"})
	if err != nil {
		t.Fatalf("LoadPromptComponents: %v", err)
	}
	pc.Defs = "Defs"
	out := pc.Compose()
	if !strings.Contains(out, "## Personality") || !strings.Contains(out, "## Tool Usage Conventions") {
		t.Fatalf("expected compose to include personality and tools sections")
	}
	if !strings.Contains(out, "## Relevant Skills") || !strings.Contains(out, "Docker skill") {
		t.Fatalf("expected skills in compose output")
	}
}
