package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/evidence"
	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/llm"
	"github.com/kai-agent/kai/internal/policy"
)

type Call struct {
	Name string          `json:"name"`
	Args json.RawMessage `json:"args"`
}

type Result struct {
	Tool    string `json:"tool"`
	Success bool   `json:"success"`
	Output  string `json:"output,omitempty"`
	Error   string `json:"error,omitempty"`
}

type Definition struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

func (d Definition) ToLLMDef() llm.ToolDef {
	return llm.ToolDef{Name: d.Name, Description: d.Description, InputSchema: d.InputSchema}
}

type Dependencies struct {
	Executor executor.Executor
	Evidence *evidence.Logger
	Reporter channels.Dispatcher
	Target   string
	Policy   *policy.Policy
}

type Tool interface {
	Definition() Definition
	Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error)
}

type Registry struct {
	items map[string]Tool
}

func NewRegistry() *Registry {
	return &Registry{items: make(map[string]Tool)}
}

func (r *Registry) Register(t Tool) error {
	def := t.Definition()
	if _, exists := r.items[def.Name]; exists {
		return fmt.Errorf("tool already registered: %s", def.Name)
	}
	r.items[def.Name] = t
	return nil
}

func (r *Registry) Definitions() []Definition {
	out := make([]Definition, 0, len(r.items))
	for _, t := range r.items {
		out = append(out, t.Definition())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (r *Registry) LLMDefinitions() []llm.ToolDef {
	defs := r.Definitions()
	out := make([]llm.ToolDef, 0, len(defs))
	for _, d := range defs {
		out = append(out, d.ToLLMDef())
	}
	return out
}

func (r *Registry) Execute(ctx context.Context, calls []llm.ToolCall, deps Dependencies) ([]Result, error) {
	results := make([]Result, 0, len(calls))
	for _, c := range calls {
		tool, ok := r.items[c.Name]
		if !ok {
			results = append(results, Result{Tool: c.Name, Success: false, Error: "unknown tool"})
			continue
		}

		args := c.Args
		if len(args) == 0 {
			args = json.RawMessage("{}")
		}
		call := Call{Name: c.Name, Args: args}
		res, err := tool.Invoke(ctx, call, deps)
		if err != nil {
			results = append(results, Result{Tool: c.Name, Success: false, Error: err.Error()})
			continue
		}
		if res.Tool == "" {
			res.Tool = c.Name
		}
		results = append(results, res)
	}
	return results, nil
}
