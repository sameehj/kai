package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// OllamaAgent implements the Agent interface using a local Ollama server.
type OllamaAgent struct {
	baseURL string
	model   string
	client  *http.Client
}

// NewOllamaAgent constructs an agent backed by a local LLM.
func NewOllamaAgent() (*OllamaAgent, error) {
	baseURL := os.Getenv("OLLAMA_HOST")
	if baseURL == "" {
		baseURL = "http://localhost:11434"
	}

	model := os.Getenv("OLLAMA_MODEL")
	if model == "" {
		if modelOverrides.Ollama != "" {
			model = modelOverrides.Ollama
		} else {
			model = "llama2"
		}
	}

	return &OllamaAgent{
		baseURL: strings.TrimRight(baseURL, "/"),
		model:   model,
		client:  &http.Client{Timeout: 60 * time.Second},
	}, nil
}

// Analyze sends the investigation context to a local Ollama server.
func (a *OllamaAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	prompt := buildPrompt(req)

	body := map[string]interface{}{
		"model":  a.model,
		"prompt": prompt,
		"stream": false,
		"format": "json",
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+"/api/generate", bytes.NewBuffer(payload))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("ollama request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("ollama API error: %s", resp.Status)
	}

	var result struct {
		Response string `json:"response"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	var analysis AnalysisResponse
	if err := json.Unmarshal([]byte(result.Response), &analysis); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}

	return &analysis, nil
}

// Close implements the Agent interface.
func (a *OllamaAgent) Close() error {
	return nil
}
