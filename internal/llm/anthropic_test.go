package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/kai-agent/kai/internal/config"
)

func TestAnthropicChatParsesContentBlocks(t *testing.T) {
	p := NewAnthropic(config.LLMConfig{
		Provider: "anthropic",
		Model:    "claude-sonnet",
		APIKey:   "test-key",
		BaseURL:  "https://example.invalid/v1",
	}).(*AnthropicProvider)

	p.httpClient.Transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if got := req.Header.Get("x-api-key"); got != "test-key" {
			t.Fatalf("unexpected x-api-key: %q", got)
		}
		return httpResponse(200, `{
  "content": [
    {"type":"text","text":"running"},
    {"type":"tool_use","id":"toolu_1","name":"system.info","input":{"verbose":true}}
  ]
}`), nil
	})

	resp, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "info"}}, nil)
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
	if resp.FinalMessage != "running" {
		t.Fatalf("unexpected final message: %q", resp.FinalMessage)
	}
	if len(resp.ToolCalls) != 1 || resp.ToolCalls[0].Name != "system.info" {
		t.Fatalf("unexpected tool calls: %+v", resp.ToolCalls)
	}
	var args map[string]bool
	if err := json.Unmarshal(resp.ToolCalls[0].Args, &args); err != nil {
		t.Fatalf("unmarshal args: %v", err)
	}
	if !args["verbose"] {
		t.Fatalf("unexpected args: %+v", args)
	}
}

func TestAnthropicToolNameMappingRoundTrip(t *testing.T) {
	p := NewAnthropic(config.LLMConfig{
		Provider: "anthropic",
		Model:    "claude-sonnet",
		APIKey:   "test-key",
		BaseURL:  "https://example.invalid/v1",
	}).(*AnthropicProvider)

	p.httpClient.Transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var payload map[string]any
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		tools, ok := payload["tools"].([]any)
		if !ok || len(tools) != 1 {
			t.Fatalf("expected one tool in request, got %#v", payload["tools"])
		}
		t0 := tools[0].(map[string]any)
		if t0["name"] != "exec_run" {
			t.Fatalf("expected anthropic-safe tool name exec_run, got %v", t0["name"])
		}
		return httpResponse(200, `{
  "content": [
    {"type":"tool_use","id":"toolu_1","name":"exec_run","input":{"cmd":["uname","-a"]}}
  ]
}`), nil
	})

	resp, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "kernel"}}, []ToolDef{
		{Name: "exec.run", Description: "run command", InputSchema: map[string]any{"type": "object"}},
	})
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
	if len(resp.ToolCalls) != 1 {
		t.Fatalf("expected 1 tool call, got %d", len(resp.ToolCalls))
	}
	if resp.ToolCalls[0].Name != "exec.run" {
		t.Fatalf("expected original tool name exec.run, got %q", resp.ToolCalls[0].Name)
	}
}
