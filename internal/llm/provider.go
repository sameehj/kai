package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/kai-agent/kai/internal/config"
)

type Role string

const (
	RoleSystem Role = "system"
	RoleUser   Role = "user"
	RoleTool   Role = "tool"
	RoleAssist Role = "assistant"
)

type Message struct {
	Role    Role   `json:"role"`
	Content string `json:"content"`
}

type ToolCall struct {
	ID   string          `json:"id"`
	Name string          `json:"name"`
	Args json.RawMessage `json:"args"`
}

type ToolResult struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Success bool   `json:"success"`
	Output  string `json:"output"`
}

type ToolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type Response struct {
	FinalMessage string     `json:"finalMessage"`
	ToolCalls    []ToolCall `json:"toolCalls,omitempty"`
}

func (r Response) HasToolCalls() bool { return len(r.ToolCalls) > 0 }

type Provider interface {
	Chat(ctx context.Context, messages []Message, tools []ToolDef) (Response, error)
}

func NewProvider(cfg config.LLMConfig) (Provider, error) {
	resolved := cfg
	switch strings.ToLower(strings.TrimSpace(resolved.Provider)) {
	case "anthropic":
		resolved.Model = normalizeAnthropicModel(resolved.Model)
		if strings.TrimSpace(resolved.APIKey) == "" {
			resolved.APIKey = strings.TrimSpace(os.Getenv("ANTHROPIC_API_KEY"))
		}
		return NewAnthropic(resolved), nil
	case "openai":
		if strings.TrimSpace(resolved.APIKey) == "" {
			resolved.APIKey = firstNonEmptyEnv("OPENAI_API_KEY", "CHATGPT_API_KEY")
		}
		return NewOpenAI(resolved), nil
	case "codex":
		if strings.TrimSpace(resolved.APIKey) == "" {
			resolved.APIKey = firstNonEmptyEnv("CODEX_API_KEY", "OPENAI_API_KEY")
		}
		if strings.TrimSpace(resolved.Model) == "" {
			resolved.Model = "codex-mini-latest"
		}
		return NewOpenAI(resolved), nil
	case "ollama":
		return NewOllama(resolved), nil
	case "openrouter":
		if strings.TrimSpace(resolved.APIKey) == "" {
			resolved.APIKey = firstNonEmptyEnv("OPENROUTER_API_KEY", "OPENAI_API_KEY")
		}
		if strings.TrimSpace(resolved.BaseURL) == "" {
			resolved.BaseURL = "https://openrouter.ai/api/v1"
		}
		return NewOpenAI(resolved), nil
	default:
		return nil, fmt.Errorf("unsupported provider: %s", cfg.Provider)
	}
}

func normalizeAnthropicModel(model string) string {
	m := strings.TrimSpace(model)
	if m == "" {
		return "claude-3-5-sonnet-latest"
	}
	switch strings.ToLower(m) {
	case "claude-sonnet-4-5-20250514":
		// Legacy internal identifier; map to Anthropic public model alias.
		return "claude-3-5-sonnet-latest"
	default:
		return m
	}
}

func firstNonEmptyEnv(keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
	}
	return ""
}

type stubProvider struct {
	name string
}

func (p *stubProvider) Chat(_ context.Context, messages []Message, _ []ToolDef) (Response, error) {
	if len(messages) == 0 {
		return Response{}, errors.New("no messages")
	}
	return Response{FinalMessage: "[" + p.name + " stub] " + messages[len(messages)-1].Content}, nil
}

func mustRawJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

func normalizeJSONArg(raw json.RawMessage) json.RawMessage {
	trim := bytes.TrimSpace(raw)
	if len(trim) == 0 {
		return mustRawJSON(map[string]any{})
	}
	if trim[0] == '"' {
		var s string
		if err := json.Unmarshal(trim, &s); err == nil {
			sb := []byte(s)
			if json.Valid(sb) {
				return sb
			}
		}
		return mustRawJSON(map[string]any{})
	}
	if !json.Valid(trim) {
		return mustRawJSON(map[string]any{})
	}
	return trim
}
