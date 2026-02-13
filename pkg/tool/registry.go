package tool

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/sameehj/kai/pkg/exec"
)

type Tool interface {
	Name() string
	Description() string
	Schema() map[string]interface{}
	Execute(ctx context.Context, input map[string]interface{}) (string, error)
}

type Registry struct {
	tools map[string]Tool
}

func NewRegistry() *Registry {
	r := &Registry{tools: make(map[string]Tool)}

	executor := &exec.SafeExecutor{Timeout: 30 * time.Second, MaxOutput: 1024 * 1024, Blocklist: []string{"rm -rf /", "dd if=", "mkfs"}}
	r.Register(&ExecTool{executor: executor})
	r.Register(&ReadTool{})
	r.Register(&WriteTool{})
	r.Register(&LsTool{})
	r.Register(&SearchTool{})
	r.Register(&ReplaceTool{})

	return r
}

func (r *Registry) Register(t Tool) {
	if t == nil {
		return
	}
	r.tools[t.Name()] = t
}

func (r *Registry) Get(name string) Tool {
	return r.tools[name]
}

func (r *Registry) Schema() string {
	var buf strings.Builder
	buf.WriteString("## Available Tools\n\n")
	for _, tool := range r.tools {
		buf.WriteString(fmt.Sprintf("- %s: %s\n", tool.Name(), tool.Description()))
	}
	return buf.String()
}

func (r *Registry) List() []Tool {
	out := make([]Tool, 0, len(r.tools))
	for _, tool := range r.tools {
		out = append(out, tool)
	}
	return out
}

func (r *Registry) Definitions() []Definition {
	out := make([]Definition, 0, len(r.tools))
	for _, tool := range r.tools {
		out = append(out, Definition{
			Name:        tool.Name(),
			Description: tool.Description(),
			InputSchema: tool.Schema(),
		})
	}
	return out
}
