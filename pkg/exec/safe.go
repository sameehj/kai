package exec

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type Result struct {
	Stdout string
	Stderr string
	Code   int
}

type SafeExecutor struct {
	Timeout   time.Duration
	MaxOutput int
	Blocklist []string
}

type OutputTruncatedError struct{}

func (OutputTruncatedError) Error() string {
	return "output truncated"
}

type BlockedCommandError struct {
	Pattern string
}

func (e BlockedCommandError) Error() string {
	return "command blocked"
}

func (e *SafeExecutor) Run(command string, workingDir string) (*Result, error) {
	if command == "" {
		return nil, errors.New("command is required")
	}
	if blocked, pattern := e.isBlocked(command); blocked {
		return nil, BlockedCommandError{Pattern: pattern}
	}

	ctx := context.Background()
	if e.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, e.Timeout)
		defer cancel()
	}

	cmd := ShellCommand(command)
	cmd = exec.CommandContext(ctx, cmd.Path, cmd.Args[1:]...)
	if workingDir != "" {
		cmd.Dir = workingDir
	}

	stdoutBuf := &limitedBuffer{limit: e.MaxOutput}
	stderrBuf := &limitedBuffer{limit: e.MaxOutput}

	cmd.Stdout = stdoutBuf
	cmd.Stderr = stderrBuf

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		if ctx.Err() != nil {
			return &Result{Stdout: stdoutBuf.String(), Stderr: stderrBuf.String(), Code: exitCode}, ctx.Err()
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, err
		}
	}

	if stdoutBuf.truncated || stderrBuf.truncated {
		return &Result{Stdout: stdoutBuf.String(), Stderr: stderrBuf.String(), Code: exitCode}, OutputTruncatedError{}
	}

	return &Result{Stdout: stdoutBuf.String(), Stderr: stderrBuf.String(), Code: exitCode}, nil
}

func ShellCommand(command string) *exec.Cmd {
	switch runtime.GOOS {
	case "windows":
		return exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", command)
	default:
		return exec.Command("sh", "-c", command)
	}
}

func (e *SafeExecutor) isBlocked(command string) (bool, string) {
	if len(e.Blocklist) == 0 {
		return false, ""
	}
	normalized := strings.ToLower(command)
	base := strings.ToLower(filepath.Base(command))
	for _, blocked := range e.Blocklist {
		pattern := strings.ToLower(blocked)
		if strings.Contains(normalized, pattern) || strings.Contains(base, pattern) {
			return true, blocked
		}
	}
	return false, ""
}

type limitedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (l *limitedBuffer) Write(p []byte) (int, error) {
	if l.limit <= 0 {
		return l.buf.Write(p)
	}
	remaining := l.limit - l.buf.Len()
	if remaining <= 0 {
		l.truncated = true
		return len(p), nil
	}
	if len(p) > remaining {
		l.truncated = true
		_, _ = l.buf.Write(p[:remaining])
		return len(p), nil
	}
	return l.buf.Write(p)
}

func (l *limitedBuffer) String() string {
	return l.buf.String()
}

var _ io.Writer = (*limitedBuffer)(nil)
