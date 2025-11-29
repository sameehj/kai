package system

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// ExecuteRequest describes a CLI command to run safely.
type ExecuteRequest struct {
	Command []string
	Timeout time.Duration
	WorkDir string
}

// ExecuteResponse contains the command output and metadata.
type ExecuteResponse struct {
	Stdout   string
	Stderr   string
	ExitCode int
	Duration time.Duration
	Error    error
}

// Executor runs CLI commands with safety constraints.
type Executor struct {
	defaultTimeout time.Duration
}

// NewExecutor creates an executor with default settings.
func NewExecutor() *Executor {
	return &Executor{
		defaultTimeout: 30 * time.Second,
	}
}

// Execute runs a command with timeout and resource limits.
func (e *Executor) Execute(ctx context.Context, req ExecuteRequest) (*ExecuteResponse, error) {
	if len(req.Command) == 0 {
		return nil, fmt.Errorf("empty command")
	}

	// Apply timeout
	timeout := req.Timeout
	if timeout == 0 {
		timeout = e.defaultTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	start := time.Now()

	// Build command
	cmd := exec.CommandContext(ctx, req.Command[0], req.Command[1:]...)
	if req.WorkDir != "" {
		cmd.Dir = req.WorkDir
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// Run command
	err := cmd.Run()

	duration := time.Since(start)

	resp := &ExecuteResponse{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		Duration: duration,
		Error:    err,
	}

	// Get exit code or propagate fatal errors
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				resp.ExitCode = status.ExitStatus()
			}
		} else if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("command timed out after %v", timeout)
		} else {
			return nil, fmt.Errorf("command failed: %w", err)
		}
	}

	return resp, nil
}

// TemplateCommand replaces {{param}} placeholders with actual values.
func TemplateCommand(cmd []string, params map[string]interface{}) []string {
	result := make([]string, len(cmd))
	for i, arg := range cmd {
		result[i] = templateString(arg, params)
	}
	return result
}

func templateString(s string, params map[string]interface{}) string {
	for key, val := range params {
		placeholder := fmt.Sprintf("{{%s}}", key)
		s = strings.ReplaceAll(s, placeholder, fmt.Sprintf("%v", val))
	}
	return s
}
