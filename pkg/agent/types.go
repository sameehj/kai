package agent

import "context"

// Agent represents an LLM-based agent that can analyze data.
type Agent interface {
	Analyze(ctx context.Context, req AnalysisRequest) (*AnalysisResponse, error)
}

// AnalysisRequest contains inputs for the agent.
type AnalysisRequest struct {
	Type   AgentType        // analysis, correlation, decision, explanation
	Inputs []StepOutput     // Outputs from previous steps
	Memory []IncidentRecord // Historical context
	Prompt string           // Optional override
}

type AgentType string

const (
	AgentTypeAnalysis    AgentType = "analysis"
	AgentTypeCorrelation AgentType = "correlation"
	AgentTypeDecision    AgentType = "decision"
	AgentTypeExplanation AgentType = "explanation"
)

// StepOutput represents output from a sensor or previous agent.
type StepOutput struct {
	StepID string
	Data   interface{}
}

// IncidentRecord represents a past incident (placeholder for now).
type IncidentRecord struct {
	RootCause  string
	Resolution string
}

// AnalysisResponse contains the agent's output.
type AnalysisResponse struct {
	RootCause         string                 `json:"root_cause"`
	AffectedComponent string                 `json:"affected_component"`
	RecommendedAction string                 `json:"recommended_action"`
	Confidence        float64                `json:"confidence"`
	Reasoning         string                 `json:"reasoning"`
	RawData           map[string]interface{} `json:"raw_data,omitempty"`
}
