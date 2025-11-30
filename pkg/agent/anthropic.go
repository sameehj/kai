package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	defaultModel     = "claude-sonnet-4-20250514"
	defaultMaxTokens = 4096
	anthropicAPIURL  = "https://api.anthropic.com/v1/messages"
)

// AnthropicAgent implements Agent using Claude API.
type AnthropicAgent struct {
	apiKey     string
	model      string
	maxTokens  int
	httpClient *http.Client
}

// NewAnthropicAgent creates a new Claude-based agent.
func NewAnthropicAgent() (*AnthropicAgent, error) {
	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("ANTHROPIC_API_KEY environment variable not set")
	}

	model := defaultModel
	if modelOverrides.Claude != "" {
		model = modelOverrides.Claude
	} else if envModel := os.Getenv("KAI_CLAUDE_MODEL"); envModel != "" {
		model = envModel
	}

	return &AnthropicAgent{
		apiKey:    apiKey,
		model:     model,
		maxTokens: defaultMaxTokens,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}, nil
}

// Analyze sends data to Claude for analysis.
func (a *AnthropicAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	prompt := buildPrompt(req)

	response, err := a.callClaude(ctx, prompt)
	if err != nil {
		return nil, fmt.Errorf("call claude: %w", err)
	}

	return a.parseResponse(response)
}

func (a *AnthropicAgent) callClaude(ctx context.Context, prompt string) (string, error) {
	reqBody := map[string]interface{}{
		"model":      a.model,
		"max_tokens": a.maxTokens,
		"messages": []map[string]string{
			{
				"role":    "user",
				"content": prompt,
			},
		},
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, anthropicAPIURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", a.apiKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")

	resp, err := a.httpClient.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var apiResp struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := json.Unmarshal(respBody, &apiResp); err != nil {
		return "", fmt.Errorf("parse response: %w", err)
	}

	if apiResp.Error.Message != "" {
		return "", fmt.Errorf("API error: %s", apiResp.Error.Message)
	}

	if len(apiResp.Content) == 0 {
		return "", fmt.Errorf("empty response from API")
	}

	return apiResp.Content[0].Text, nil
}

func (a *AnthropicAgent) parseResponse(response string) (*AnalysisResponse, error) {
	clean := cleanJSONResponse(response)

	var result AnalysisResponse
	if err := json.Unmarshal([]byte(clean), &result); err != nil {
		return nil, fmt.Errorf("parse JSON response: %w (response: %s)", err, clean)
	}

	return &result, nil
}

// Close implements the Agent interface.
func (a *AnthropicAgent) Close() error {
	return nil
}

func cleanJSONResponse(s string) string {
	trimmed := strings.TrimSpace(s)
	trimmed = strings.TrimPrefix(trimmed, "```json")
	trimmed = strings.TrimPrefix(trimmed, "```")
	trimmed = strings.TrimSpace(trimmed)
	trimmed = strings.TrimSuffix(trimmed, "```")
	trimmed = strings.TrimSpace(trimmed)
	return trimmed
}
