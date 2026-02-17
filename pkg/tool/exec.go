package tool

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/sameehj/kai/pkg/exec"
)

type ExecTool struct {
	executor *exec.SafeExecutor
}

func (t *ExecTool) Name() string {
	return "exec"
}

func (t *ExecTool) Description() string {
	return "Execute a shell command and return stdout, stderr, and exit code"
}

func (t *ExecTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"command": map[string]string{
				"type":        "string",
				"description": "Shell command to execute",
			},
			"cwd": map[string]string{
				"type":        "string",
				"description": "Working directory (optional)",
			},
		},
		"required": []string{"command"},
	}
}

func (t *ExecTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	cmd, _ := input["command"].(string)
	cwd, _ := input["cwd"].(string)
	if os.Getenv("KAI_DEBUG") != "" {
		log.Printf("tool: exec command=%s cwd=%s", truncate(cmd, 200), cwd)
	}
	res, err := t.executor.Run(cmd, cwd)
	if res == nil {
		// Input validation and blocked-command errors may return nil result.
		if err != nil {
			return fmt.Sprintf("Command failed before execution: %v", err), nil
		}
		return "Command produced no result.", nil
	}
	out := formatExecResult(res.Code, res.Stdout, res.Stderr)
	if err != nil {
		out += fmt.Sprintf("\nNote: %v", err)
	}
	return out, nil
}

func truncate(s string, limit int) string {
	if limit <= 0 {
		return s
	}
	if len(s) <= limit {
		return s
	}
	return strings.TrimSpace(s[:limit]) + "..."
}

func formatExecResult(code int, stdout, stderr string) string {
	stdout = strings.TrimSpace(stdout)
	stderr = strings.TrimSpace(stderr)
	if stdout == "" {
		stdout = "(empty)"
	}
	if stderr == "" {
		stderr = "(empty)"
	}
	return fmt.Sprintf("Exit code: %d\nStdout:\n%s\nStderr:\n%s", code, stdout, stderr)
}
