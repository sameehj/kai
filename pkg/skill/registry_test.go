package skill

import (
	"os"
	"path/filepath"
	"slices"
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
	if got := Normalize("mailing-list"); got != "mailing list" {
		t.Fatalf("expected mailing list, got %q", got)
	}
}

func TestSelectRelevantNestedSkillFromMetadata(t *testing.T) {
	dir := t.TempDir()
	skillDir := filepath.Join(dir, "skills", "kernel", "lore-search")
	if err := os.MkdirAll(skillDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	content := `---
name: linux-kernel-mailing-list-search
description: Search and analyze Linux kernel mailing lists on lore.kernel.org.
---
`
	if err := os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte(content), 0o644); err != nil {
		t.Fatalf("write skill: %v", err)
	}

	reg := NewRegistry(dir)
	list := reg.List()
	if !slices.Contains(list, "kernel/lore-search") {
		t.Fatalf("expected nested skill listed, got %v", list)
	}

	msgs := []string{"can you check the linux kernel mailing list and latest linus comments?"}
	out := reg.SelectRelevant(msgs)
	if !slices.Contains(out, "kernel/lore-search") {
		t.Fatalf("expected kernel/lore-search selected, got %v", out)
	}
}
