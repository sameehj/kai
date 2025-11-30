package agent

import "context"

// AgentType defines which AI backend should be used.
type AgentType string

const (
	AgentTypeClaude AgentType = "claude"
	AgentTypeOpenAI AgentType = "openai"
	AgentTypeGemini AgentType = "gemini"
	AgentTypeLlama  AgentType = "llama"
	AgentTypeMock   AgentType = "mock"
)

// Agent represents an AI backend that can analyze investigation data.
type Agent interface {
	Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error)
	Close() error
}

// AnalysisRequest is backend-agnostic.
type AnalysisRequest struct {
	Type    string       `json:"type"`    // analysis, correlation, decision
	Context []StepOutput `json:"context"` // Previous step outputs
	Prompt  string       `json:"prompt"`  // Custom prompt (optional)
}

// StepOutput represents data from previous steps.
type StepOutput struct {
	StepID string                 `json:"step_id"`
	Data   map[string]interface{} `json:"data"`
}

// AnalysisResponse is standardized across all backends.
type AnalysisResponse struct {
	RootCause         string  `json:"root_cause"`
	AffectedComponent string  `json:"affected_component"`
	RecommendedAction string  `json:"recommended_action"`
	Confidence        float64 `json:"confidence"`
	Reasoning         string  `json:"reasoning"`
}

// ModelOverrides allows callers to customize which model each backend should use.
type ModelOverrides struct {
	Claude string
	OpenAI string
	Gemini string
	Ollama string
}

var modelOverrides ModelOverrides

// SetModelOverrides configures package-wide model overrides.
func SetModelOverrides(overrides ModelOverrides) {
	modelOverrides = overrides
}
