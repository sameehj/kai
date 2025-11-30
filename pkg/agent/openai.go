package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

// OpenAIAgent implements the Agent interface using OpenAI's Chat Completions API.
type OpenAIAgent struct {
	apiKey string
	model  string
	client *http.Client
}

// NewOpenAIAgent constructs a ChatGPT-backed agent.
func NewOpenAIAgent() (*OpenAIAgent, error) {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("OPENAI_API_KEY not set")
	}

	model := "gpt-4-turbo-preview"
	if modelOverrides.OpenAI != "" {
		model = modelOverrides.OpenAI
	} else if envModel := os.Getenv("KAI_OPENAI_MODEL"); envModel != "" {
		model = envModel
	}

	return &OpenAIAgent{
		apiKey: apiKey,
		model:  model,
		client: &http.Client{Timeout: 60 * time.Second},
	}, nil
}

// Analyze sends the investigation context to OpenAI.
func (a *OpenAIAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	prompt := buildPrompt(req)

	body := map[string]interface{}{
		"model": a.model,
		"messages": []map[string]string{
			{
				"role":    "system",
				"content": "You are an expert SRE analyzing infrastructure issues. Respond with JSON only.",
			},
			{
				"role":    "user",
				"content": prompt,
			},
		},
		"response_format": map[string]string{"type": "json_object"},
		"temperature":     0.3,
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.openai.com/v1/chat/completions", bytes.NewBuffer(payload))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+a.apiKey)

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("openai request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("openai API error: %s", resp.Status)
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	if len(result.Choices) == 0 {
		return nil, fmt.Errorf("openai response missing content")
	}

	var content string
	if err := json.Unmarshal(result.Choices[0].Message.Content, &content); err != nil {
		var parts []struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(result.Choices[0].Message.Content, &parts); err != nil || len(parts) == 0 {
			return nil, fmt.Errorf("openai response missing content text: %w", err)
		}
		content = parts[0].Text
	}

	var analysis AnalysisResponse
	if err := json.Unmarshal([]byte(content), &analysis); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}

	return &analysis, nil
}

// Close implements the Agent interface.
func (a *OpenAIAgent) Close() error {
	return nil
}
