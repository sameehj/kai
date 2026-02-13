package llm

import (
	"testing"

	"github.com/sameehj/kai/pkg/agent"
)

func TestConvertOpenAIMessagesToolResultNonEmpty(t *testing.T) {
	t.Logf("tool_result should map to non-empty tool message")
	msgs := []agent.CompletionMessage{
		{
			Role: "assistant",
			Content: []agent.ContentBlock{
				{Type: "tool_result", ToolUseID: "t1"},
			},
		},
	}
	out := convertOpenAIMessages(msgs)
	if len(out) != 1 {
		t.Fatalf("expected 1 message, got %d", len(out))
	}
	if out[0].Role != "tool" {
		t.Fatalf("expected tool role, got %q", out[0].Role)
	}
	if out[0].Content == "" {
		t.Fatalf("expected non-empty tool content")
	}
}

func TestConvertOpenAIMessagesToolUse(t *testing.T) {
	t.Logf("tool_use should map to tool_calls")
	msgs := []agent.CompletionMessage{
		{
			Role: "assistant",
			Content: []agent.ContentBlock{
				{Type: "tool_use", ID: "t1", Name: "exec", Input: map[string]interface{}{"command": "echo hi"}},
			},
		},
	}
	out := convertOpenAIMessages(msgs)
	if len(out) != 1 {
		t.Fatalf("expected 1 message, got %d", len(out))
	}
	if len(out[0].ToolCalls) != 1 {
		t.Fatalf("expected 1 tool_call, got %d", len(out[0].ToolCalls))
	}
	if out[0].ToolCalls[0].Function.Name != "exec" {
		t.Fatalf("expected exec tool, got %q", out[0].ToolCalls[0].Function.Name)
	}
}
