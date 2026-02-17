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
	responses  []*CompletionResponse
}

func (f *fakeLLM) Complete(ctx context.Context, req CompletionRequest) (*CompletionResponse, error) {
	f.callCount++
	if f.validateFn != nil {
		f.validateFn(req)
	}
	if len(f.responses) > 0 {
		idx := f.callCount - 1
		if idx < len(f.responses) {
			return f.responses[idx], nil
		}
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

type fakeExecTool struct{}

func (t *fakeExecTool) Name() string                   { return "exec" }
func (t *fakeExecTool) Description() string            { return "fake exec for tests" }
func (t *fakeExecTool) Schema() map[string]interface{} { return map[string]interface{}{"type": "object"} }
func (t *fakeExecTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	return "HTTP/1.1 200 OK\nFrom: Linus Torvalds <torvalds@linux-foundation.org>", nil
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

func TestWindowSessionMessages(t *testing.T) {
	t.Logf("ensuring session history is windowed")
	t.Setenv("KAI_HISTORY_MAX_MESSAGES", "3")
	msgs := []session.Message{
		{Role: "user", Content: "1"},
		{Role: "assistant", Content: "2"},
		{Role: "user", Content: "3"},
		{Role: "assistant", Content: "4"},
	}
	out := windowSessionMessages(msgs)
	if len(out) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(out))
	}
	if out[0].Content != "2" || out[2].Content != "4" {
		t.Fatalf("unexpected window: %+v", out)
	}
}

func TestExecuteLoopForcesLoreProbeOnBlockedResponse(t *testing.T) {
	t.Logf("should run forced exec probe once when model refuses LKML request without tool usage")
	llm := &fakeLLM{
		responses: []*CompletionResponse{
			{
				Content:    "I cannot access the mailing list due to bot protection.",
				StopReason: "end_turn",
			},
			{
				Content:    "Here are results with links.",
				StopReason: "end_turn",
			},
		},
		validateFn: func(req CompletionRequest) {
			if len(req.Messages) < 2 {
				return
			}
			last := req.Messages[len(req.Messages)-1]
			if last.Role != "user" || len(last.Content) == 0 {
				return
			}
			if req.Messages[len(req.Messages)-1].Content[0].Text == "" {
				t.Fatalf("expected forced probe user content")
			}
		},
	}
	rt := NewRuntime(&Config{Workspace: "", LLM: llm})
	rt.tools.Register(&fakeExecTool{})
	rt.policy = &policy.Policy{} // allow all tools
	sess := &session.Session{
		ID: "agent:test:main",
		Messages: []session.Message{
			{Role: "user", Content: "can you show latest linus roasting in mailing list"},
		},
	}
	out, err := rt.executeLoop(context.Background(), sess)
	if err != nil {
		t.Fatalf("executeLoop error: %v", err)
	}
	if out != "Here are results with links." {
		t.Fatalf("unexpected response: %q", out)
	}
	if llm.callCount != 2 {
		t.Fatalf("expected 2 llm calls, got %d", llm.callCount)
	}
}
