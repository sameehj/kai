package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/kai-agent/kai/internal/config"
)

func TestOllamaChatParsesToolCalls(t *testing.T) {
	p := NewOllama(config.LLMConfig{Provider: "ollama", Model: "llama3", BaseURL: "https://example.invalid"}).(*OllamaProvider)

	p.httpClient.Transport = roundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return httpResponse(200, `{
  "message": {
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "exec.run",
          "arguments": {"cmd": ["uname", "-a"]}
        }
      }
    ]
  }
}`), nil
	})

	resp, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "kernel"}}, nil)
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
	if len(resp.ToolCalls) != 1 || resp.ToolCalls[0].Name != "exec.run" {
		t.Fatalf("unexpected tool calls: %+v", resp.ToolCalls)
	}
	var args map[string]any
	if err := json.Unmarshal(resp.ToolCalls[0].Args, &args); err != nil {
		t.Fatalf("unmarshal args: %v", err)
	}
}

func TestOllamaChatSendsToolsSchema(t *testing.T) {
	p := NewOllama(config.LLMConfig{Provider: "ollama", Model: "llama3", BaseURL: "https://example.invalid"}).(*OllamaProvider)
	p.httpClient.Transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		var payload map[string]any
		if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		tools, ok := payload["tools"].([]any)
		if !ok || len(tools) != 1 {
			t.Fatalf("expected one tool schema, got %#v", payload["tools"])
		}
		t0 := tools[0].(map[string]any)
		if t0["type"] != "function" {
			t.Fatalf("expected tool type=function, got %v", t0["type"])
		}
		fn, ok := t0["function"].(map[string]any)
		if !ok {
			t.Fatalf("missing function field in tool schema: %#v", t0)
		}
		if fn["name"] != "exec" {
			t.Fatalf("unexpected tool name %v", fn["name"])
		}
		return httpResponse(200, `{"message":{"content":"ok","tool_calls":[]}}`), nil
	})

	_, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "kernel?"}}, []ToolDef{
		{Name: "exec", Description: "run command", InputSchema: map[string]any{"type": "object"}},
	})
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
}
