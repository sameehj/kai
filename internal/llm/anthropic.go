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

type AnthropicProvider struct {
	cfg        config.LLMConfig
	endpoint   string
	httpClient *http.Client
}

func NewAnthropic(cfg config.LLMConfig) Provider {
	ep := strings.TrimSpace(cfg.BaseURL)
	if ep == "" {
		ep = "https://api.anthropic.com/v1/messages"
	} else {
		ep = strings.TrimRight(ep, "/")
		if !strings.HasSuffix(ep, "/messages") {
			ep = ep + "/messages"
		}
	}
	return &AnthropicProvider{
		cfg:      cfg,
		endpoint: ep,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

func (p *AnthropicProvider) Chat(ctx context.Context, messages []Message, tools []ToolDef) (Response, error) {
	if strings.TrimSpace(p.cfg.APIKey) == "" {
		return Response{}, fmt.Errorf("anthropic api key is empty")
	}

	system, apiMessages := p.toAPIMessages(messages)
	reqBody := map[string]any{
		"model":      p.cfg.Model,
		"max_tokens": 1024,
		"messages":   apiMessages,
	}
	if system != "" {
		reqBody["system"] = system
	}
	nameMap := map[string]string{}
	if len(tools) > 0 {
		reqBody["tools"], nameMap = p.toAPITools(tools)
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
	req.Header.Set("x-api-key", p.cfg.APIKey)
	req.Header.Set("anthropic-version", "2023-06-01")

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
		msg := string(body)
		if resp.StatusCode == http.StatusNotFound && strings.Contains(msg, "not_found_error") && strings.Contains(strings.ToLower(msg), "model") {
			return Response{}, fmt.Errorf("anthropic model %q not found. Update llm.model (or run `kai init`)", p.cfg.Model)
		}
		return Response{}, fmt.Errorf("anthropic status %d: %s", resp.StatusCode, string(body))
	}

	var parsed struct {
		Content []struct {
			Type  string          `json:"type"`
			Text  string          `json:"text"`
			ID    string          `json:"id"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return Response{}, err
	}

	out := Response{}
	for _, block := range parsed.Content {
		switch block.Type {
		case "text":
			if block.Text != "" {
				if out.FinalMessage != "" {
					out.FinalMessage += "\n"
				}
				out.FinalMessage += block.Text
			}
		case "tool_use":
			name := block.Name
			if original, ok := nameMap[block.Name]; ok {
				name = original
			}
			out.ToolCalls = append(out.ToolCalls, ToolCall{
				ID:   block.ID,
				Name: name,
				Args: normalizeJSONArg(block.Input),
			})
		}
	}
	return out, nil
}

func (p *AnthropicProvider) toAPIMessages(messages []Message) (string, []map[string]any) {
	var systemParts []string
	out := make([]map[string]any, 0, len(messages))
	for _, m := range messages {
		switch m.Role {
		case RoleSystem:
			systemParts = append(systemParts, m.Content)
		case RoleUser:
			out = append(out, map[string]any{
				"role": "user",
				"content": []map[string]any{{
					"type": "text",
					"text": m.Content,
				}},
			})
		case RoleAssist:
			out = append(out, map[string]any{
				"role": "assistant",
				"content": []map[string]any{{
					"type": "text",
					"text": m.Content,
				}},
			})
		case RoleTool:
			out = append(out, map[string]any{
				"role": "user",
				"content": []map[string]any{{
					"type": "text",
					"text": "tool_result:\n" + m.Content,
				}},
			})
		}
	}
	return strings.Join(systemParts, "\n\n"), out
}

func (p *AnthropicProvider) toAPITools(tools []ToolDef) ([]map[string]any, map[string]string) {
	out := make([]map[string]any, 0, len(tools))
	nameMap := make(map[string]string, len(tools))
	for _, t := range tools {
		apiName := anthropicToolName(t.Name)
		nameMap[apiName] = t.Name
		out = append(out, map[string]any{
			"name":         apiName,
			"description":  t.Description,
			"input_schema": t.InputSchema,
		})
	}
	return out, nameMap
}

func anthropicToolName(name string) string {
	// Anthropic custom tool names allow only [a-zA-Z0-9_-].
	replacer := strings.NewReplacer(
		".", "_",
		":", "_",
		"/", "_",
		" ", "_",
	)
	out := replacer.Replace(name)
	if out == "" {
		return "tool"
	}
	return out
}
