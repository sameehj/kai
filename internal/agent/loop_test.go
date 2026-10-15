package agent

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/llm"
	"github.com/kai-agent/kai/internal/tools"
)

type mockProvider struct {
	calls int
}

func (m *mockProvider) Chat(_ context.Context, _ []llm.Message, _ []llm.ToolDef) (llm.Response, error) {
	m.calls++
	if m.calls == 1 {
		return llm.Response{ToolCalls: []llm.ToolCall{{Name: "echo", Args: json.RawMessage(`{"text":"from tool"}`)}}}, nil
	}
	return llm.Response{FinalMessage: "done"}, nil
}

type loopEchoTool struct{}

func (loopEchoTool) Definition() tools.Definition {
	return tools.Definition{Name: "echo", Description: "echo"}
}

func (loopEchoTool) Invoke(_ context.Context, call tools.Call, _ tools.Dependencies) (tools.Result, error) {
	var payload struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(call.Args, &payload)
	return tools.Result{Success: true, Output: payload.Text}, nil
}

func TestLoopRunOnceWithToolCall(t *testing.T) {
	dir := t.TempDir()
	session, err := OpenSession(filepath.Join(dir, "sessions", "default.jsonl"))
	if err != nil {
		t.Fatalf("open session: %v", err)
	}
	defer session.Close()

	registry := tools.NewRegistry()
	if err := registry.Register(loopEchoTool{}); err != nil {
		t.Fatalf("register tool: %v", err)
	}

	provider := &mockProvider{}
	loop := Loop{
		Provider: provider,
		Tools:    registry,
		Session:  session,
		Memory:   NewMemoryStore(filepath.Join(dir, "workspace", "MEMORY.md"), filepath.Join(dir, "workspace", "memory")),
		Executor: executor.NewLocalExecutor(),
	}

	out, err := loop.RunOnce(context.Background(), "run")
	if err != nil {
		t.Fatalf("run once: %v", err)
	}
	if !strings.Contains(out, "done") {
		t.Fatalf("expected output to contain done, got %q", out)
	}
	if provider.calls != 2 {
		t.Fatalf("expected 2 provider calls, got %d", provider.calls)
	}

	msgs, err := session.Messages()
	if err != nil {
		t.Fatalf("session messages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 persisted messages, got %d", len(msgs))
	}
}
