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

// GeminiAgent implements the Agent interface via Google Gemini.
type GeminiAgent struct {
	apiKey string
	model  string
	client *http.Client
}

// NewGeminiAgent constructs a Gemini-backed agent.
func NewGeminiAgent() (*GeminiAgent, error) {
	apiKey := os.Getenv("GOOGLE_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("GOOGLE_API_KEY not set")
	}

	model := "gemini-pro"
	if modelOverrides.Gemini != "" {
		model = modelOverrides.Gemini
	} else if envModel := os.Getenv("KAI_GEMINI_MODEL"); envModel != "" {
		model = envModel
	}

	return &GeminiAgent{
		apiKey: apiKey,
		model:  model,
		client: &http.Client{Timeout: 60 * time.Second},
	}, nil
}

// Analyze sends the investigation context to Gemini.
func (a *GeminiAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	prompt := buildPrompt(req)

	body := map[string]interface{}{
		"contents": []map[string]interface{}{
			{
				"parts": []map[string]string{
					{"text": prompt},
				},
			},
		},
		"generationConfig": map[string]interface{}{
			"temperature": 0.3,
		},
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	url := fmt.Sprintf("https://generativelanguage.googleapis.com/v1/models/%s:generateContent?key=%s", a.model, a.apiKey)

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBuffer(payload))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("gemini request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("gemini API error: %s", resp.Status)
	}

	var result struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	if len(result.Candidates) == 0 || len(result.Candidates[0].Content.Parts) == 0 {
		return nil, fmt.Errorf("gemini response missing content")
	}

	content := result.Candidates[0].Content.Parts[0].Text

	var analysis AnalysisResponse
	if err := json.Unmarshal([]byte(content), &analysis); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}

	return &analysis, nil
}

// Close implements the Agent interface.
func (a *GeminiAgent) Close() error {
	return nil
}
