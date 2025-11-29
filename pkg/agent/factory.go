package agent

import (
	"context"
	"fmt"
)

// NewAgent creates an agent of the specified type.
func NewAgent(agentType string) (Agent, error) {
	switch agentType {
	case "anthropic", "claude", "":
		return NewAnthropicAgent()
	case "mock":
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
