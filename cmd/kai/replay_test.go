package main

import (
	"bytes"
	"compress/gzip"
	"strings"
	"testing"
)

func TestUnifiedDiff(t *testing.T) {
	d := unifiedDiff("a.txt", "old\n", "new\n")
	if !strings.Contains(d, "--- a/a.txt") || !strings.Contains(d, "+++ b/a.txt") {
		t.Fatalf("unexpected header: %s", d)
	}
	if !strings.Contains(d, "-old") || !strings.Contains(d, "+new") {
		t.Fatalf("expected content diff, got: %s", d)
	}
}

func TestDecodeMaybeGzip(t *testing.T) {
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	_, _ = zw.Write([]byte("hello\n"))
	_ = zw.Close()

	v := b.Bytes()
	got := decodeMaybeGzip(&v)
	if got != "hello\n" {
		t.Fatalf("unexpected decoded value: %q", got)
	}
}
