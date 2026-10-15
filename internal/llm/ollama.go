package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/kai-agent/kai/internal/config"
)

type OllamaProvider struct {
	cfg        config.LLMConfig
	endpoint   string
	httpClient *http.Client
}

func NewOllama(cfg config.LLMConfig) Provider {
	ep := strings.TrimSpace(cfg.BaseURL)
	if ep == "" {
		ep = "http://localhost:11434/api/chat"
	} else {
		ep = strings.TrimRight(ep, "/")
		if !strings.HasSuffix(ep, "/api/chat") {
			ep = ep + "/api/chat"
		}
	}
	return &OllamaProvider{
		cfg:      cfg,
		endpoint: ep,
		httpClient: &http.Client{
			Timeout: 120 * time.Second,
		},
	}
}

func (p *OllamaProvider) Chat(ctx context.Context, messages []Message, tools []ToolDef) (Response, error) {
	reqBody := map[string]any{
		"model":    p.cfg.Model,
		"stream":   false,
		"messages": p.toAPIMessages(messages),
	}
	if len(tools) > 0 {
		reqBody["tools"] = p.toAPITools(tools)
	}

	b, err := json.Marshal(reqBody)
	if err != nil {
		return Response{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, bytes.NewReader(b))
	if err != nil {
		return Response{}, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return Response{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, err
	}
	if resp.StatusCode >= 300 {
		return Response{}, fmt.Errorf("ollama status %d: %s", resp.StatusCode, string(body))
	}

	var parsed struct {
		Message struct {
			Content   string `json:"content"`
			ToolCalls []struct {
				Function struct {
					Name      string          `json:"name"`
					Arguments json.RawMessage `json:"arguments"`
				} `json:"function"`
			} `json:"tool_calls"`
		} `json:"message"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return Response{}, err
	}

	out := Response{FinalMessage: parsed.Message.Content}
	for i, tc := range parsed.Message.ToolCalls {
		out.ToolCalls = append(out.ToolCalls, ToolCall{
			ID:   fmt.Sprintf("ollama_%d", i),
			Name: tc.Function.Name,
			Args: normalizeJSONArg(tc.Function.Arguments),
		})
	}
	return out, nil
}

func (p *OllamaProvider) toAPIMessages(messages []Message) []map[string]any {
	out := make([]map[string]any, 0, len(messages))
	for _, m := range messages {
		role := string(m.Role)
		if role == string(RoleTool) {
			role = string(RoleUser)
		}
		out = append(out, map[string]any{
			"role":    role,
			"content": m.Content,
		})
	}
	return out
}

func (p *OllamaProvider) toAPITools(tools []ToolDef) []map[string]any {
	out := make([]map[string]any, 0, len(tools))
	for _, t := range tools {
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"parameters":  t.InputSchema,
			},
		})
	}
	return out
}
