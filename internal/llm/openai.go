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

type OpenAIProvider struct {
	cfg        config.LLMConfig
	endpoint   string
	httpClient *http.Client
}

func NewOpenAI(cfg config.LLMConfig) Provider {
	ep := strings.TrimSpace(cfg.BaseURL)
	if ep == "" {
		ep = "https://api.openai.com/v1/chat/completions"
	} else {
		ep = strings.TrimRight(ep, "/")
		if !strings.HasSuffix(ep, "/chat/completions") {
			ep = ep + "/chat/completions"
		}
	}
	return &OpenAIProvider{
		cfg:      cfg,
		endpoint: ep,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

func (p *OpenAIProvider) Chat(ctx context.Context, messages []Message, tools []ToolDef) (Response, error) {
	if strings.TrimSpace(p.cfg.APIKey) == "" {
		return Response{}, fmt.Errorf("openai api key is empty")
	}

	reqBody := map[string]any{
		"model":    p.cfg.Model,
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
	req.Header.Set("Authorization", "Bearer "+p.cfg.APIKey)

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
		return Response{}, fmt.Errorf("openai status %d: %s", resp.StatusCode, string(body))
	}

	var parsed struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string          `json:"name"`
						Arguments json.RawMessage `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return Response{}, err
	}
	if len(parsed.Choices) == 0 {
		return Response{}, fmt.Errorf("openai: no choices in response")
	}

	choice := parsed.Choices[0].Message
	out := Response{FinalMessage: choice.Content}
	for _, tc := range choice.ToolCalls {
		out.ToolCalls = append(out.ToolCalls, ToolCall{
			ID:   tc.ID,
			Name: tc.Function.Name,
			Args: normalizeJSONArg(tc.Function.Arguments),
		})
	}
	return out, nil
}

func (p *OpenAIProvider) toAPIMessages(messages []Message) []map[string]any {
	out := make([]map[string]any, 0, len(messages))
	for _, m := range messages {
		role := string(m.Role)
		if m.Role == RoleTool {
			role = string(RoleUser)
		}
		out = append(out, map[string]any{
			"role":    role,
			"content": m.Content,
		})
	}
	return out
}

func (p *OpenAIProvider) toAPITools(tools []ToolDef) []map[string]any {
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
