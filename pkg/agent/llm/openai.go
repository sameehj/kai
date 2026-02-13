package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/sameehj/kai/pkg/agent"
)

const defaultOpenAIModel = "gpt-4o-mini"

type OpenAIClient struct {
	apiKey string
	model  string
	http   *http.Client
}

func NewOpenAIClient(apiKey, model string) *OpenAIClient {
	if model == "" {
		model = defaultOpenAIModel
	}
	return &OpenAIClient{
		apiKey: apiKey,
		model:  model,
		http:   &http.Client{Timeout: 60 * time.Second},
	}
}

func NewOpenAIFromEnv() *OpenAIClient {
	return NewOpenAIClient(os.Getenv("OPENAI_API_KEY"), os.Getenv("OPENAI_MODEL"))
}

func (c *OpenAIClient) Complete(ctx context.Context, req agent.CompletionRequest) (*agent.CompletionResponse, error) {
	if c.apiKey == "" {
		return nil, errors.New("missing OPENAI_API_KEY")
	}
	msgs := convertOpenAIMessages(req.Messages)
	if req.Prompt != "" {
		msgs = append([]openAIMessage{{Role: "system", Content: req.Prompt}}, msgs...)
	}
	payload := openAIRequest{
		Model:    c.model,
		Messages: msgs,
		Tools:    convertOpenAITools(req.Tools),
	}
	if req.MaxTokens > 0 {
		payload.MaxTokens = req.MaxTokens
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.openai.com/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)

	if openAIDebugEnabled() {
		log.Printf("openai: model=%s messages=%d tools=%d", c.model, len(msgs), len(payload.Tools))
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("openai error: %s (set OPENAI_MODEL to a valid model name if needed)", strings.TrimSpace(string(b)))
	}
	var out openAIResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if len(out.Choices) == 0 {
		return nil, errors.New("openai error: empty response")
	}
	choice := out.Choices[0]
	blocks := make([]agent.ContentBlock, 0)
	toolCalls := make([]agent.ToolCall, 0)
	contentText := ""
	if choice.Message.Content != "" {
		contentText = choice.Message.Content
		blocks = append(blocks, agent.ContentBlock{Type: "text", Text: choice.Message.Content})
	}
	for _, call := range choice.Message.ToolCalls {
		toolCalls = append(toolCalls, agent.ToolCall{
			ID:    call.ID,
			Name:  call.Function.Name,
			Input: decodeArgs(call.Function.Arguments),
		})
		blocks = append(blocks, agent.ContentBlock{
			Type:  "tool_use",
			ID:    call.ID,
			Name:  call.Function.Name,
			Input: decodeArgs(call.Function.Arguments),
		})
	}
	return &agent.CompletionResponse{
		Content:    contentText,
		Blocks:     blocks,
		ToolCalls:  toolCalls,
		StopReason: choice.FinishReason,
	}, nil
}

type openAIRequest struct {
	Model     string          `json:"model"`
	Messages  []openAIMessage `json:"messages"`
	Tools     []openAITool    `json:"tools,omitempty"`
	MaxTokens int             `json:"max_tokens,omitempty"`
}

type openAIMessage struct {
	Role       string           `json:"role"`
	Content    string           `json:"content,omitempty"`
	ToolCalls  []openAIToolCall `json:"tool_calls,omitempty"`
	ToolCallID string           `json:"tool_call_id,omitempty"`
}

type openAITool struct {
	Type     string            `json:"type"`
	Function openAIFunctionDef `json:"function"`
}

type openAIFunctionDef struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	Parameters  map[string]interface{} `json:"parameters"`
}

type openAIToolCall struct {
	ID       string             `json:"id"`
	Type     string             `json:"type"`
	Function openAIFunctionCall `json:"function"`
}

type openAIFunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type openAIResponse struct {
	Choices []openAIChoice `json:"choices"`
}

type openAIChoice struct {
	Message      openAIMessage `json:"message"`
	FinishReason string        `json:"finish_reason"`
}

func convertOpenAIMessages(msgs []agent.CompletionMessage) []openAIMessage {
	out := make([]openAIMessage, 0, len(msgs))
	for _, m := range msgs {
		role := normalizeOpenAIRole(m.Role)
		var textParts []string
		var toolCalls []openAIToolCall
		var toolResults []openAIMessage

		for _, b := range m.Content {
			switch b.Type {
			case "text":
				if b.Text != "" {
					textParts = append(textParts, b.Text)
				}
			case "tool_use":
				toolCalls = append(toolCalls, openAIToolCall{
					ID:   b.ID,
					Type: "function",
					Function: openAIFunctionCall{
						Name:      b.Name,
						Arguments: mustJSON(b.Input),
					},
				})
			case "tool_result":
				content := extractText(b)
				if content == "" {
					content = "(no output)"
				}
				toolResults = append(toolResults, openAIMessage{
					Role:       "tool",
					Content:    content,
					ToolCallID: b.ToolUseID,
				})
			}
		}

		if len(toolCalls) > 0 {
			out = append(out, openAIMessage{
				Role:      "assistant",
				Content:   strings.Join(textParts, ""),
				ToolCalls: toolCalls,
			})
		} else if len(textParts) > 0 || len(toolResults) == 0 {
			out = append(out, openAIMessage{
				Role:    role,
				Content: strings.Join(textParts, ""),
			})
		}
		for _, tr := range toolResults {
			out = append(out, tr)
		}
	}
	return out
}

func convertOpenAITools(tools []agent.ToolDefinition) []openAITool {
	out := make([]openAITool, 0, len(tools))
	for _, t := range tools {
		out = append(out, openAITool{
			Type: "function",
			Function: openAIFunctionDef{
				Name:        t.Name,
				Description: t.Description,
				Parameters:  t.InputSchema,
			},
		})
	}
	return out
}

func extractText(b agent.ContentBlock) string {
	if b.Text != "" {
		return b.Text
	}
	for _, c := range b.Content {
		if c.Type == "text" && c.Text != "" {
			return c.Text
		}
	}
	return ""
}

func mustJSON(v map[string]interface{}) string {
	if v == nil {
		return "{}"
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(b)
}

func decodeArgs(s string) map[string]interface{} {
	if s == "" {
		return nil
	}
	var out map[string]interface{}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return nil
	}
	return out
}

func normalizeOpenAIRole(role string) string {
	switch role {
	case "user", "assistant", "system":
		return role
	default:
		return "user"
	}
}

func openAIDebugEnabled() bool {
	return os.Getenv("KAI_DEBUG") != ""
}
