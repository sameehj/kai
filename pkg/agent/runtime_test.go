package agent

import (
	"context"
	"testing"
	"time"

	"github.com/sameehj/kai/pkg/policy"
	"github.com/sameehj/kai/pkg/session"
)

type fakeLLM struct {
	t          *testing.T
	callCount  int
	validateFn func(req CompletionRequest)
}

func (f *fakeLLM) Complete(ctx context.Context, req CompletionRequest) (*CompletionResponse, error) {
	f.callCount++
	if f.validateFn != nil {
		f.validateFn(req)
	}
	if f.callCount == 1 {
		return &CompletionResponse{
			ToolCalls: []ToolCall{{ID: "t1", Name: "empty", Input: map[string]interface{}{}}},
		}, nil
	}
	return &CompletionResponse{
		Content:    "ok",
		StopReason: "end_turn",
	}, nil
}

type emptyTool struct{}

func (t *emptyTool) Name() string                   { return "empty" }
func (t *emptyTool) Description() string            { return "returns empty output" }
func (t *emptyTool) Schema() map[string]interface{} { return map[string]interface{}{"type": "object"} }
func (t *emptyTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	return "", nil
}

func TestExecuteLoopToolResultNonEmptyText(t *testing.T) {
	t.Logf("validating non-empty tool_result text for Anthropic schema")
	llm := &fakeLLM{
		t: t,
		validateFn: func(req CompletionRequest) {
			if len(req.Messages) < 2 {
				return
			}
			last := req.Messages[len(req.Messages)-1]
			if last.Role != "user" {
				return
			}
			for _, b := range last.Content {
				if b.Type == "tool_result" {
					if len(b.Content) == 0 || b.Content[0].Text == "" {
						t.Fatalf("expected non-empty tool_result text, got %+v", b)
					}
				}
			}
		},
	}
	rt := NewRuntime(&Config{Workspace: "", LLM: llm})
	rt.tools.Register(&emptyTool{})
	rt.policy = &policy.Policy{} // allow all tools

	sess := &session.Session{ID: "agent:test:main"}
	_, err := rt.executeLoop(context.Background(), sess)
	if err != nil {
		t.Fatalf("executeLoop error: %v", err)
	}
}

func TestConvertSessionMessagesRoleCoercion(t *testing.T) {
	t.Logf("ensuring non user/assistant roles are coerced to user")
	msgs := []session.Message{
		{Role: "user", Content: "hi", Timestamp: time.Now()},
		{Role: "tool", Content: "tool output", Timestamp: time.Now()},
		{Role: "assistant", Content: "ok", Timestamp: time.Now()},
	}
	out := convertSessionMessages(msgs)
	if out[0].Role != "user" {
		t.Fatalf("expected user, got %q", out[0].Role)
	}
	if out[1].Role != "user" {
		t.Fatalf("expected tool role coerced to user, got %q", out[1].Role)
	}
	if out[2].Role != "assistant" {
		t.Fatalf("expected assistant, got %q", out[2].Role)
	}
}

func TestLLMTimeoutFromEnv(t *testing.T) {
	t.Logf("ensuring timeout reads from KAI_LLM_TIMEOUT_SECONDS")
	t.Setenv("KAI_LLM_TIMEOUT_SECONDS", "12")
	if got := llmTimeout(); got != 12*time.Second {
		t.Fatalf("expected 12s, got %v", got)
	}
}
