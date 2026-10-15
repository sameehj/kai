package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type searchTool struct{}

type searchArgs struct {
	Query string `json:"query"`
	Scope string `json:"scope"`
}

func (searchTool) Definition() Definition {
	return Definition{Name: "search", Description: "Search files/content on target or web", InputSchema: objSchema(req("query", strSchema("query string")), req("scope", strSchema("files|content|web")))}
}

func (searchTool) Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error) {
	var a searchArgs
	if err := decodeArgs(call.Args, &a); err != nil {
		return Result{}, err
	}
	a.Scope = strings.ToLower(strings.TrimSpace(a.Scope))
	start := time.Now()
	var output string
	switch a.Scope {
	case "files":
		res, err := deps.Executor.Run(ctx, []string{"sh", "-lc", "find . -name '*" + strings.ReplaceAll(a.Query, "'", "") + "*' 2>/dev/null | head -200"})
		if err != nil {
			return Result{}, err
		}
		output = res.Stdout
	case "content":
		res, err := deps.Executor.Run(ctx, []string{"sh", "-lc", "grep -RIn --line-number -- " + shellEscape(a.Query) + " . 2>/dev/null | head -200"})
		if err != nil {
			return Result{}, err
		}
		output = res.Stdout
	case "web":
		u := "https://duckduckgo.com/html/?q=" + url.QueryEscape(a.Query)
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return Result{}, err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 128*1024))
		output = string(b)
	default:
		return Result{}, fmt.Errorf("scope must be files|content|web")
	}
	payload := map[string]any{"query": a.Query, "scope": a.Scope, "results": output}
	jb, _ := json.Marshal(payload)
	_ = logEvidence(deps, "search", map[string]any{"query": a.Query, "scope": a.Scope}, payload, time.Since(start).Milliseconds(), nil, "allow")
	return Result{Tool: "search", Success: true, Output: string(jb)}, nil
}
