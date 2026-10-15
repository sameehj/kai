package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadWithDotEnvExpansion(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "kai.json")
	envPath := filepath.Join(dir, ".kai", ".env")

	if err := os.MkdirAll(filepath.Dir(envPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(envPath, []byte("ANTHROPIC_API_KEY=abc123\nSSH_HOST=vm.local\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfgJSON := `{
  "llm": {"provider":"anthropic", "model":"x", "api_key":"${ANTHROPIC_API_KEY}"},
  "executor": {"type":"ssh", "ssh":{"host":"${SSH_HOST}", "user":"u", "keyFile":"/k"}},
  "policy": {"default_mode":"confirm", "allow_sudo":true, "allow":[], "confirm":[], "block":[]},
  "channels": {"slack":{"enabled":false}, "telegram":{"enabled":false}, "email":{"enabled":false}},
  "skills": {"dirs":[], "disabled":[]}
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0o600); err != nil {
		t.Fatal(err)
	}

	_ = os.Setenv("ANTHROPIC_API_KEY", "")
	_ = os.Setenv("SSH_HOST", "")
	t.Setenv("HOME", dir)
	cfg, err := LoadFromPath(cfgPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.LLM.APIKey != "abc123" {
		t.Fatalf("expected api key from .env, got %q", cfg.LLM.APIKey)
	}
	if cfg.Executor.SSH.Host != "vm.local" {
		t.Fatalf("expected host from .env, got %q", cfg.Executor.SSH.Host)
	}
}

func TestLoadMissingConfigReturnsDefault(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	cfg, err := LoadFromPath(filepath.Join(dir, "missing.json"))
	if err != nil {
		t.Fatalf("load missing: %v", err)
	}
	if cfg.Executor.Type != "local" {
		t.Fatalf("expected local executor default, got %q", cfg.Executor.Type)
	}
}

func TestWriteEnvKey(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	if err := os.WriteFile(p, []byte("A=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteEnvKey(p, "A", "2"); err != nil {
		t.Fatal(err)
	}
	if err := WriteEnvKey(p, "B", "3"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if s == "" || !containsLine(s, "A=2") || !containsLine(s, "B=3") {
		t.Fatalf("unexpected .env content:\n%s", s)
	}
}

func containsLine(s, line string) bool {
	for _, l := range strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n") {
		if l == line {
			return true
		}
	}
	return false
}
