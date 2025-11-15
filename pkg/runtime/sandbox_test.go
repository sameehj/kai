package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSandboxManagerEnsureAndRemove(t *testing.T) {
	root := t.TempDir()
	manager := newSandboxManager(root)

	sb, err := manager.Ensure("demo@1.0.0")
	if err != nil {
		t.Fatalf("ensure sandbox: %v", err)
	}
	if sb == nil || sb.BPFFSPath == "" {
		t.Fatalf("expected sandbox info with bpffs path")
	}
	if _, err := os.Stat(sb.BPFFSPath); err != nil {
		t.Fatalf("expected bpffs directory to exist: %v", err)
	}

	manager.Remove("demo@1.0.0")
	if _, err := os.Stat(filepath.Dir(sb.BPFFSPath)); !os.IsNotExist(err) {
		t.Fatalf("expected sandbox directory to be removed, got %v", err)
	}
}
