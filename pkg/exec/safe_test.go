package exec

import (
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestSafeExecutorBlocklist(t *testing.T) {
	exec := &SafeExecutor{Blocklist: []string{"rm -rf /"}}
	_, err := exec.Run("rm -rf /tmp", "")
	if err == nil {
		t.Fatalf("expected blocklist error")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "blocked") {
		t.Fatalf("expected blocked error, got %v", err)
	}
}

func TestSafeExecutorTimeout(t *testing.T) {
	exec := &SafeExecutor{Timeout: 50 * time.Millisecond}
	cmd := "sleep 1"
	if runtime.GOOS == "windows" {
		cmd = "Start-Sleep -Seconds 1"
	}
	start := time.Now()
	_, err := exec.Run(cmd, "")
	if err == nil {
		t.Fatalf("expected timeout error")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("timeout did not trigger quickly")
	}
}

func TestSafeExecutorOutputTruncation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("output truncation test uses sh printf")
	}
	exec := &SafeExecutor{MaxOutput: 10}
	res, err := exec.Run("printf '123456789012345'", "")
	if err == nil {
		t.Fatalf("expected truncation error")
	}
	if _, ok := err.(OutputTruncatedError); !ok {
		t.Fatalf("expected OutputTruncatedError, got %T", err)
	}
	if len(res.Stdout) != 10 {
		t.Fatalf("expected truncated stdout length 10, got %d", len(res.Stdout))
	}
}

func TestSafeExecutorSuccess(t *testing.T) {
	exec := &SafeExecutor{Timeout: 2 * time.Second}
	res, err := exec.Run("echo hello", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(res.Stdout, "hello") {
		t.Fatalf("unexpected stdout: %q", res.Stdout)
	}
}
