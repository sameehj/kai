package tool

import (
	"context"
	"fmt"

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
	res, err := t.executor.Run(cmd, cwd)
	if err != nil {
		return fmt.Sprintf("Exit code %d\nStderr: %s\nStdout: %s", res.Code, res.Stderr, res.Stdout), nil
	}
	return res.Stdout, nil
}
