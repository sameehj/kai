package mcp

import "testing"

func TestParsePackageID(t *testing.T) {
	t.Parallel()

	name, version := parsePackageID("falco-syscalls@0.37.0")
	if name != "falco-syscalls" || version != "0.37.0" {
		t.Fatalf("unexpected parse result %s@%s", name, version)
	}

	name, version = parsePackageID("tracee-syscalls")
	if version != "latest" {
		t.Fatalf("expected fallback version latest, got %s", version)
	}
}

func TestMapKeys(t *testing.T) {
	t.Parallel()

	input := map[string]int{"a": 1, "b": 2}
	keys := mapKeys(input)
	if len(keys) != 2 {
		t.Fatalf("expected 2 keys, got %d", len(keys))
	}
}
