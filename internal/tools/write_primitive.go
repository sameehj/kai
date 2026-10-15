package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type writeTool struct{}

type writeArgs struct {
	Path        string `json:"path"`
	Content     string `json:"content"`
	Mode        string `json:"mode,omitempty"`
	Permissions string `json:"permissions,omitempty"`
}

func (writeTool) Definition() Definition {
	return Definition{Name: "write", Description: "Write content to target file", InputSchema: objSchema(req("path", strSchema("file path")), req("content", strSchema("content")), opt("mode", strSchema("overwrite|append|create")), opt("permissions", strSchema("optional mode like 0644")))}
}

func (writeTool) Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error) {
	var a writeArgs
	if err := decodeArgs(call.Args, &a); err != nil {
		return Result{}, err
	}
	a.Path = strings.TrimSpace(a.Path)
	if a.Path == "" {
		return Result{}, fmt.Errorf("path is required")
	}
	if a.Mode == "" {
		a.Mode = "create"
	}
	start := time.Now()
	before, _ := deps.Executor.ReadFile(ctx, a.Path)
	content := a.Content
	if a.Mode == "append" {
		content = string(before) + a.Content
	}
	if a.Mode == "create" && len(before) > 0 {
		return Result{Tool: "write", Success: false, Error: "file already exists"}, nil
	}
	if err := deps.Executor.WriteFile(ctx, a.Path, []byte(content)); err != nil {
		_ = logEvidence(deps, "write", map[string]any{"path": a.Path, "mode": a.Mode}, nil, time.Since(start).Milliseconds(), err, "confirm")
		return Result{}, err
	}
	if strings.TrimSpace(a.Permissions) != "" {
		_, _ = deps.Executor.Run(ctx, []string{"sh", "-lc", "chmod " + a.Permissions + " " + shellEscape(a.Path)})
	}
	after, _ := deps.Executor.ReadFile(ctx, a.Path)
	payload := map[string]any{"path": a.Path, "mode": a.Mode, "before_hash": hashBytes(before), "after_hash": hashBytes(after)}
	b, _ := json.Marshal(payload)
	_ = logEvidence(deps, "write", map[string]any{"path": a.Path, "mode": a.Mode, "permissions": a.Permissions}, payload, time.Since(start).Milliseconds(), nil, "confirm")
	return Result{Tool: "write", Success: true, Output: string(b)}, nil
}

func hashBytes(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func shellEscape(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
