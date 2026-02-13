package skill

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSelectRelevant(t *testing.T) {
	dir := t.TempDir()
	skillsDir := filepath.Join(dir, "skills", "docker")
	if err := os.MkdirAll(skillsDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(skillsDir, "SKILL.md"), []byte("docker info"), 0o644); err != nil {
		t.Fatalf("write skill: %v", err)
	}

	reg := NewRegistry(dir)
	msgs := []string{"How do I use Docker here?"}
	out := reg.SelectRelevant(msgs)
	if len(out) != 1 || out[0] != "docker" {
		t.Fatalf("expected docker, got %v", out)
	}
	if !reg.Exists("docker") {
		t.Fatalf("expected skill to exist")
	}
}

func TestNormalize(t *testing.T) {
	if got := Normalize("  DoCkEr "); got != "docker" {
		t.Fatalf("expected docker, got %q", got)
	}
}
