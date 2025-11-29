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

	return &AnthropicAgent{
		apiKey:    apiKey,
		model:     defaultModel,
		maxTokens: defaultMaxTokens,
		httpClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}, nil
}

// Analyze sends data to Claude for analysis.
func (a *AnthropicAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	prompt := a.buildPrompt(req)

	response, err := a.callClaude(ctx, prompt)
	if err != nil {
		return nil, fmt.Errorf("call claude: %w", err)
	}

	return a.parseResponse(response)
}

func (a *AnthropicAgent) buildPrompt(req AnalysisRequest) string {
	if req.Prompt != "" {
		return req.Prompt
	}

	switch req.Type {
	case AgentTypeCorrelation:
		return a.buildCorrelationPrompt(req)
	case AgentTypeDecision:
		return a.buildDecisionPrompt(req)
	case AgentTypeExplanation:
		return a.buildAnalysisPrompt(req)
	default:
		return a.buildAnalysisPrompt(req)
	}
}

func (a *AnthropicAgent) buildAnalysisPrompt(req AnalysisRequest) string {
	inputsJSON, _ := json.MarshalIndent(req.Inputs, "", "  ")

	return fmt.Sprintf(`You are a Linux kernel and infrastructure performance expert analyzing system metrics.

Given the following sensor outputs:
%s

Your task:
1. Identify the root cause of any performance issues
2. Determine which component is affected (process, pod, kernel module, etc.)
3. Recommend an action to resolve the issue (rollback, restart, scale, investigate further)
4. Provide a confidence score (0.0 to 1.0)
5. Explain your reasoning

Respond ONLY with valid JSON in this exact format:
{
  "root_cause": "one sentence description",
  "affected_component": "specific component name",
  "recommended_action": "rollback|restart|scale|investigate|none",
  "confidence": 0.85,
  "reasoning": "brief explanation of your analysis"
}

DO NOT include any text outside the JSON object.`, string(inputsJSON))
}

func (a *AnthropicAgent) buildCorrelationPrompt(req AnalysisRequest) string {
	inputsJSON, _ := json.MarshalIndent(req.Inputs, "", "  ")

	return fmt.Sprintf(`You are analyzing multiple system metrics to find correlations.

Sensor data:
%s

Find patterns and correlations between these metrics. Respond with JSON:
{
  "root_cause": "summary of correlation",
  "affected_component": "component",
  "recommended_action": "action",
  "confidence": 0.85,
  "reasoning": "correlation explanation"
}`, string(inputsJSON))
}

func (a *AnthropicAgent) buildDecisionPrompt(req AnalysisRequest) string {
	inputsJSON, _ := json.MarshalIndent(req.Inputs, "", "  ")

	return fmt.Sprintf(`You are a decision-making agent determining if action should be taken.

Analysis results:
%s

Decide: Should we take automated action? Respond with JSON:
{
  "root_cause": "decision summary",
  "affected_component": "component",
  "recommended_action": "execute|escalate|monitor",
  "confidence": 0.85,
  "reasoning": "decision rationale"
}`, string(inputsJSON))
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

func cleanJSONResponse(s string) string {
	trimmed := strings.TrimSpace(s)
	trimmed = strings.TrimPrefix(trimmed, "```json")
	trimmed = strings.TrimPrefix(trimmed, "```")
	trimmed = strings.TrimSpace(trimmed)
	trimmed = strings.TrimSuffix(trimmed, "```")
	trimmed = strings.TrimSpace(trimmed)
	return trimmed
}
