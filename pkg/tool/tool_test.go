package tool

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegistryDefinitions(t *testing.T) {
	t.Logf("registry should expose tool definitions")
	r := NewRegistry()
	defs := r.Definitions()
	if len(defs) == 0 {
		t.Fatalf("expected tool definitions")
	}
	if r.Get("read") == nil {
		t.Fatalf("expected read tool")
	}
}

func TestReadWriteReplaceSearchLs(t *testing.T) {
	t.Logf("exercise basic file tools")
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "file.txt")

	write := &WriteTool{}
	if _, err := write.Execute(ctx, map[string]interface{}{"path": path, "content": "hello world"}); err != nil {
		t.Fatalf("write: %v", err)
	}

	read := &ReadTool{}
	out, err := read.Execute(ctx, map[string]interface{}{"path": path})
	if err != nil || out != "hello world" {
		t.Fatalf("read: %v out=%q", err, out)
	}

	repl := &ReplaceTool{}
	if _, err := repl.Execute(ctx, map[string]interface{}{"path": path, "find": "world", "replace": "kai"}); err != nil {
		t.Fatalf("replace: %v", err)
	}
	out, _ = read.Execute(ctx, map[string]interface{}{"path": path})
	if out != "hello kai" {
		t.Fatalf("replace not applied: %q", out)
	}

	search := &SearchTool{}
	matches, err := search.Execute(ctx, map[string]interface{}{"path": dir, "query": "kai"})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !strings.Contains(matches, path) {
		t.Fatalf("expected search to return path, got %q", matches)
	}

	ls := &LsTool{}
	listing, err := ls.Execute(ctx, map[string]interface{}{"path": dir})
	if err != nil {
		t.Fatalf("ls: %v", err)
	}
	if !strings.Contains(listing, "file.txt") {
		t.Fatalf("expected file.txt in listing, got %q", listing)
	}
}

func TestExpandPath(t *testing.T) {
	t.Logf("expandPath should resolve ~ to home")
	home, _ := os.UserHomeDir()
	got := expandPath("~/test-path")
	if !strings.HasPrefix(got, home) {
		t.Fatalf("expected path under home, got %q", got)
	}
}
