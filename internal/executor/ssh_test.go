package executor

import (
	"testing"
)

func TestShellQuote(t *testing.T) {
	in := "abc'xyz"
	got := shellQuote(in)
	want := `'abc'"'"'xyz'`
	if got != want {
		t.Fatalf("shellQuote mismatch: got %q want %q", got, want)
	}
}

func TestShellJoin(t *testing.T) {
	got := shellJoin([]string{"echo", "hello world", "x"})
	want := `'echo' 'hello world' 'x'`
	if got != want {
		t.Fatalf("shellJoin mismatch: got %q want %q", got, want)
	}
}

func TestNewSSHExecutorRequiresHost(t *testing.T) {
	_, err := NewSSHExecutor(SSHConfig{})
	if err == nil {
		t.Fatal("expected host required error")
	}
}
