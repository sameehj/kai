package agent

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"
)

// NewAgent auto-detects which backend to use based on available credentials.
func NewAgent() (Agent, error) {
	if key := os.Getenv("ANTHROPIC_API_KEY"); key != "" {
		return NewAnthropicAgent()
	}

	if key := os.Getenv("OPENAI_API_KEY"); key != "" {
		return NewOpenAIAgent()
	}

	if key := os.Getenv("GOOGLE_API_KEY"); key != "" {
		return NewGeminiAgent()
	}

	if os.Getenv("OLLAMA_HOST") != "" || checkOllamaAvailable() {
		return NewOllamaAgent()
	}

	return NewMockAgent(), nil
}

// NewAgentByType creates a specific agent backend.
func NewAgentByType(agentType AgentType) (Agent, error) {
	switch agentType {
	case AgentTypeClaude:
		return NewAnthropicAgent()
	case AgentTypeOpenAI:
		return NewOpenAIAgent()
	case AgentTypeGemini:
		return NewGeminiAgent()
	case AgentTypeLlama:
		return NewOllamaAgent()
	case AgentTypeMock, "":
		return NewMockAgent(), nil
	default:
		return nil, fmt.Errorf("unknown agent type: %s", agentType)
	}
}

// MockAgent is a testing agent that returns hardcoded responses.
type MockAgent struct{}

// NewMockAgent constructs a mock agent for testing.
func NewMockAgent() *MockAgent {
	return &MockAgent{}
}

// Analyze returns deterministic data for offline testing.
func (m *MockAgent) Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error) {
	return &AnalysisResponse{
		RootCause:         "High CPU usage in json_parse() function",
		AffectedComponent: "api-server-v2",
		RecommendedAction: "rollback",
		Confidence:        0.85,
		Reasoning:         "Mock agent response for testing",
	}, nil
}

// Close implements the Agent interface.
func (m *MockAgent) Close() error {
	return nil
}

func checkOllamaAvailable() bool {
	baseURL := os.Getenv("OLLAMA_HOST")
	if baseURL == "" {
		baseURL = "http://localhost:11434"
	}

	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("%s/api/tags", baseURL), nil)
	if err != nil {
		return false
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK
}
