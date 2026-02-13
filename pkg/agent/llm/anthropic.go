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

const defaultAnthropicModel = "claude-3-5-sonnet-latest"

type AnthropicClient struct {
	apiKey string
	model  string
	http   *http.Client
}

func NewAnthropicClient(apiKey, model string) *AnthropicClient {
	if model == "" {
		model = defaultAnthropicModel
	}
	return &AnthropicClient{
		apiKey: apiKey,
		model:  model,
		http:   &http.Client{Timeout: 60 * time.Second},
	}
}

func NewAnthropicFromEnv() *AnthropicClient {
	return NewAnthropicClient(os.Getenv("ANTHROPIC_API_KEY"), "")
}

func (c *AnthropicClient) Complete(ctx context.Context, req agent.CompletionRequest) (*agent.CompletionResponse, error) {
	if c.apiKey == "" {
		return nil, errors.New("missing ANTHROPIC_API_KEY")
	}
	payload := anthropicRequest{
		Model:     c.model,
		MaxTokens: req.MaxTokens,
		System:    req.Prompt,
		Messages:  convertMessages(req.Messages),
		Tools:     convertTools(req.Tools),
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.anthropic.com/v1/messages", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", c.apiKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")

	if anthropicDebugEnabled() {
		log.Printf("anthropic: model=%s messages=%d tools=%d", c.model, len(payload.Messages), len(payload.Tools))
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("anthropic error: %s (set ANTHROPIC_MODEL to a valid model name if needed)", strings.TrimSpace(string(b)))
	}
	var out anthropicResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	blocks := make([]agent.ContentBlock, 0, len(out.Content))
	toolCalls := make([]agent.ToolCall, 0)
	var textBuf bytes.Buffer
	for _, blk := range out.Content {
		cb := agent.ContentBlock{
			Type: blk.Type,
			Text: blk.Text,
			ID:   blk.ID,
			Name: blk.Name,
			Input: func() map[string]interface{} {
				if blk.Input == nil {
					return nil
				}
				return blk.Input
			}(),
		}
		blocks = append(blocks, cb)
		if blk.Type == "tool_use" {
			toolCalls = append(toolCalls, agent.ToolCall{
				ID:    blk.ID,
				Name:  blk.Name,
				Input: blk.Input,
			})
		}
		if blk.Type == "text" && blk.Text != "" {
			textBuf.WriteString(blk.Text)
		}
	}
	return &agent.CompletionResponse{
		Content:    textBuf.String(),
		Blocks:     blocks,
		ToolCalls:  toolCalls,
		StopReason: out.StopReason,
	}, nil
}

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	System    string             `json:"system,omitempty"`
	Messages  []anthropicMessage `json:"messages"`
	Tools     []anthropicTool    `json:"tools,omitempty"`
}

type anthropicMessage struct {
	Role    string           `json:"role"`
	Content []anthropicBlock `json:"content"`
}

type anthropicBlock struct {
	Type      string                 `json:"type"`
	Text      string                 `json:"text,omitempty"`
	ID        string                 `json:"id,omitempty"`
	Name      string                 `json:"name,omitempty"`
	Input     map[string]interface{} `json:"input,omitempty"`
	ToolUseID string                 `json:"tool_use_id,omitempty"`
	IsError   bool                   `json:"is_error,omitempty"`
	Content   []anthropicBlock       `json:"content,omitempty"`
}

type anthropicTool struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	InputSchema map[string]interface{} `json:"input_schema"`
}

type anthropicResponse struct {
	Content    []anthropicBlock `json:"content"`
	StopReason string           `json:"stop_reason"`
}

func convertMessages(msgs []agent.CompletionMessage) []anthropicMessage {
	out := make([]anthropicMessage, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, anthropicMessage{Role: m.Role, Content: convertBlocks(m.Content)})
	}
	return out
}

func convertBlocks(blocks []agent.ContentBlock) []anthropicBlock {
	out := make([]anthropicBlock, 0, len(blocks))
	for _, b := range blocks {
		out = append(out, anthropicBlock{
			Type:      b.Type,
			Text:      b.Text,
			ID:        b.ID,
			Name:      b.Name,
			Input:     b.Input,
			ToolUseID: b.ToolUseID,
			IsError:   b.IsError,
			Content:   convertBlocks(b.Content),
		})
	}
	return out
}

func convertTools(tools []agent.ToolDefinition) []anthropicTool {
	out := make([]anthropicTool, 0, len(tools))
	for _, t := range tools {
		out = append(out, anthropicTool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		})
	}
	return out
}

func anthropicDebugEnabled() bool {
	return os.Getenv("KAI_DEBUG") != ""
}
