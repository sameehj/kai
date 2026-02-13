package agent

import "context"

type LLMClient interface {
	Complete(ctx context.Context, req CompletionRequest) (*CompletionResponse, error)
}

type CompletionRequest struct {
	Prompt    string
	Messages  []CompletionMessage
	Tools     []ToolDefinition
	MaxTokens int
}

type CompletionMessage struct {
	Role    string
	Content []ContentBlock
}

type ContentBlock struct {
	Type      string                 `json:"type"`
	Text      string                 `json:"text,omitempty"`
	ID        string                 `json:"id,omitempty"`
	Name      string                 `json:"name,omitempty"`
	Input     map[string]interface{} `json:"input,omitempty"`
	ToolUseID string                 `json:"tool_use_id,omitempty"`
	IsError   bool                   `json:"is_error,omitempty"`
	Content   []ContentBlock         `json:"content,omitempty"`
}

type ToolDefinition struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"input_schema"`
}

type CompletionResponse struct {
	Content    string
	Blocks     []ContentBlock
	ToolCalls  []ToolCall
	StopReason string
}

type ToolCall struct {
	ID    string
	Name  string
	Input map[string]interface{}
}
