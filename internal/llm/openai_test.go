package llm

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/kai-agent/kai/internal/config"
)

func TestOpenAIChatParsesToolCalls(t *testing.T) {
	p := NewOpenAI(config.LLMConfig{
		Provider: "openai",
		Model:    "gpt-4o-mini",
		APIKey:   "test-key",
		BaseURL:  "https://example.invalid/v1",
	}).(*OpenAIProvider)

	p.httpClient.Transport = roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if got := req.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("unexpected authorization header: %q", got)
		}
		return httpResponse(200, `{
  "choices": [
    {
      "message": {
        "content": "",
        "tool_calls": [
          {
            "id": "call_1",
            "function": {
              "name": "file.read",
              "arguments": "{\"path\":\"/tmp/a\"}"
            }
          }
        ]
      }
    }
  ]
}`), nil
	})

	resp, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "read file"}}, nil)
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
	if len(resp.ToolCalls) != 1 {
		t.Fatalf("expected 1 tool call, got %d", len(resp.ToolCalls))
	}
	if resp.ToolCalls[0].Name != "file.read" {
		t.Fatalf("unexpected tool name: %q", resp.ToolCalls[0].Name)
	}
	var args map[string]string
	if err := json.Unmarshal(resp.ToolCalls[0].Args, &args); err != nil {
		t.Fatalf("unmarshal args: %v", err)
	}
	if args["path"] != "/tmp/a" {
		t.Fatalf("unexpected path: %v", args)
	}
}

func TestOpenAINeedsAPIKey(t *testing.T) {
	p := NewOpenAI(config.LLMConfig{Model: "x"})
	_, err := p.Chat(context.Background(), []Message{{Role: RoleUser, Content: "hi"}}, nil)
	if err == nil || !strings.Contains(err.Error(), "api key") {
		t.Fatalf("expected api key error, got %v", err)
	}
}
