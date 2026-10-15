package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type readTool struct{}

type readArgs struct {
	Path     string `json:"path"`
	Lines    string `json:"lines,omitempty"`
	Encoding string `json:"encoding,omitempty"`
}

func (readTool) Definition() Definition {
	return Definition{Name: "read", Description: "Read a file on target or HTTP(S) URL", InputSchema: objSchema(req("path", strSchema("file path or URL")), opt("lines", strSchema("line range like 10-50 or last 100")), opt("encoding", strSchema("text encoding, default utf-8")))}
}

func (readTool) Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error) {
	var a readArgs
	if err := decodeArgs(call.Args, &a); err != nil {
		return Result{}, err
	}
	a.Path = strings.TrimSpace(a.Path)
	if a.Path == "" {
		return Result{}, fmt.Errorf("path is required")
	}
	start := time.Now()
	var data []byte
	var err error
	if strings.HasPrefix(a.Path, "http://") || strings.HasPrefix(a.Path, "https://") {
		data, err = readURL(ctx, a.Path)
	} else {
		data, err = deps.Executor.ReadFile(ctx, a.Path)
	}
	dur := time.Since(start).Milliseconds()
	if err != nil {
		_ = logEvidence(deps, "read", map[string]any{"path": a.Path, "lines": a.Lines}, nil, dur, err, "allow")
		return Result{}, err
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return Result{Tool: "read", Success: false, Error: "binary content detected"}, nil
	}
	text := string(data)
	text = applyLineSelection(text, a.Lines)
	truncated := false
	if len(text) > 64*1024 {
		text = text[:64*1024]
		truncated = true
	}
	payload := map[string]any{"content": text, "size_bytes": len(data), "truncated": truncated}
	b, _ := json.Marshal(payload)
	_ = logEvidence(deps, "read", map[string]any{"path": a.Path, "lines": a.Lines}, payload, dur, nil, "allow")
	return Result{Tool: "read", Success: true, Output: string(b)}, nil
}

func readURL(ctx context.Context, u string) ([]byte, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("http status %s", resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 512*1024))
}

func applyLineSelection(content, spec string) string {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return content
	}
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	if strings.HasPrefix(strings.ToLower(spec), "last ") {
		n, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(strings.ToLower(spec), "last ")))
		if n <= 0 || n >= len(lines) {
			return content
		}
		return strings.Join(lines[len(lines)-n:], "\n")
	}
	parts := strings.Split(spec, "-")
	if len(parts) != 2 {
		return content
	}
	start, errA := strconv.Atoi(strings.TrimSpace(parts[0]))
	end, errB := strconv.Atoi(strings.TrimSpace(parts[1]))
	if errA != nil || errB != nil || start <= 0 || end < start {
		return content
	}
	if start > len(lines) {
		return ""
	}
	if end > len(lines) {
		end = len(lines)
	}
	return strings.Join(lines[start-1:end], "\n")
}
