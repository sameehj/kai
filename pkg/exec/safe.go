package exec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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

func (e *SafeExecutor) Run(cmd string, args []string) (*Result, error) {
	if cmd == "" {
		return nil, errors.New("command is required")
	}
	if e.isBlocked(cmd) {
		return nil, fmt.Errorf("command blocked: %s", cmd)
	}

	ctx := context.Background()
	if e.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, e.Timeout)
		defer cancel()
	}

	var command *exec.Cmd
	if len(args) == 0 {
		command = ShellCommand(cmd)
		command = exec.CommandContext(ctx, command.Path, command.Args[1:]...)
	} else {
		command = exec.CommandContext(ctx, cmd, args...)
	}

	stdoutBuf := &limitedBuffer{limit: e.MaxOutput}
	stderrBuf := &limitedBuffer{limit: e.MaxOutput}

	command.Stdout = stdoutBuf
	command.Stderr = stderrBuf

	err := command.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, err
		}
	}

	if stdoutBuf.truncated || stderrBuf.truncated {
		return &Result{Stdout: stdoutBuf.String(), Stderr: stderrBuf.String(), Code: exitCode}, fmt.Errorf("output truncated")
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

func (e *SafeExecutor) isBlocked(cmd string) bool {
	if len(e.Blocklist) == 0 {
		return false
	}
	base := filepath.Base(cmd)
	for _, blocked := range e.Blocklist {
		if strings.EqualFold(blocked, cmd) || strings.EqualFold(blocked, base) {
			return true
		}
	}
	return false
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
