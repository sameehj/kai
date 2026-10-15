package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/kai-agent/kai/internal/evidence"
	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/policy"
)

type execTool struct{}

type execArgs struct {
	Command string `json:"command"`
	Timeout int    `json:"timeout,omitempty"`
	Sudo    bool   `json:"sudo,omitempty"`
}

func (execTool) Definition() Definition {
	return Definition{
		Name:        "exec",
		Description: "Execute a shell command on the current target",
		InputSchema: objSchema(req("command", strSchema("shell command")), opt("timeout", map[string]any{"type": "integer", "minimum": 1, "maximum": 300}), opt("sudo", map[string]any{"type": "boolean"})),
	}
}

func (execTool) Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error) {
	var a execArgs
	if err := decodeArgs(call.Args, &a); err != nil {
		return Result{}, err
	}
	a.Command = strings.TrimSpace(a.Command)
	if a.Command == "" {
		return Result{}, fmt.Errorf("command is required")
	}
	if a.Timeout <= 0 {
		a.Timeout = 30
	}
	if a.Timeout > 300 {
		a.Timeout = 300
	}
	if deps.Policy != nil {
		checkCmd := a.Command
		if a.Sudo {
			checkCmd = "sudo " + checkCmd
		}
		decision := deps.Policy.CheckCommand(checkCmd)
		switch decision.Decision {
		case policy.Block:
			_ = logEvidence(deps, "exec", map[string]any{"command": a.Command, "timeout": a.Timeout, "sudo": a.Sudo}, nil, 0, fmt.Errorf("blocked: %s", decision.Reason), "block")
			return Result{}, fmt.Errorf("blocked by policy: %s", decision.Reason)
		case policy.Confirm:
			_ = logEvidence(deps, "exec", map[string]any{"command": a.Command, "timeout": a.Timeout, "sudo": a.Sudo}, nil, 0, fmt.Errorf("requires confirmation: %s", decision.Reason), "confirm")
			return Result{}, fmt.Errorf("requires confirmation: %s", decision.Reason)
		}
	}

	cmd := []string{"sh", "-lc", a.Command}
	if a.Sudo {
		cmd = []string{"sudo", "sh", "-lc", a.Command}
	}

	env := map[string]string{
		"DEBIAN_FRONTEND":     "noninteractive",
		"SYSTEMD_PAGER":       "cat",
		"PAGER":               "cat",
		"GIT_TERMINAL_PROMPT": "0",
		"TERM":                "dumb",
	}
	start := time.Now()
	res, err := deps.Executor.RunWithOpts(ctx, cmd, executor.RunOpts{
		TimeoutSeconds: a.Timeout,
		Env:            env,
		MaxOutputBytes: 512 * 1024,
	})
	dur := time.Since(start).Milliseconds()
	if err != nil {
		_ = logEvidence(deps, "exec", map[string]any{"command": a.Command, "timeout": a.Timeout, "sudo": a.Sudo}, nil, dur, err, "")
		return Result{}, err
	}
	payload := map[string]any{"stdout": res.Stdout, "stderr": res.Stderr, "exit_code": res.ExitCode, "duration_ms": dur}
	b, _ := json.Marshal(payload)
	_ = logEvidence(deps, "exec", map[string]any{"command": a.Command, "timeout": a.Timeout, "sudo": a.Sudo}, payload, dur, nil, "allow")
	return Result{Tool: "exec", Success: res.ExitCode == 0, Output: string(b)}, nil
}

func logEvidence(deps Dependencies, tool string, input, output map[string]any, duration int64, err error, decision string) error {
	if deps.Evidence == nil {
		return nil
	}
	ev := evidence.Event{Tool: tool, Target: deps.Target, Input: input, Output: output, DurationMS: duration, PolicyDecision: decision}
	if err != nil {
		ev.Error = err.Error()
	}
	return deps.Evidence.Log(ev)
}
