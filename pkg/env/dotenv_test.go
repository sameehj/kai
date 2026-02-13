package env

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadFromDir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	content := "FOO=bar\n# comment\nexport BAZ=\"qux\"\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	_ = os.Unsetenv("FOO")
	_ = os.Unsetenv("BAZ")
	if err := LoadFromDir(dir); err != nil {
		t.Fatalf("LoadFromDir: %v", err)
	}
	if got := os.Getenv("FOO"); got != "bar" {
		t.Fatalf("expected FOO=bar, got %q", got)
	}
	if got := os.Getenv("BAZ"); got != "qux" {
		t.Fatalf("expected BAZ=qux, got %q", got)
	}
}

func TestLoadDoesNotOverwrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("FOO=bar\n"), 0o644); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	t.Setenv("FOO", "existing")
	if err := Load(path); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := os.Getenv("FOO"); got != "existing" {
		t.Fatalf("expected existing value preserved, got %q", got)
	}
}
