package types

import "time"

// FlowRun represents a single execution of a flow.
type FlowRun struct {
	ID        string       `json:"id"`
	FlowID    string       `json:"flowId"`
	State     FlowState    `json:"state"`
	StartedAt time.Time    `json:"startedAt"`
	EndedAt   *time.Time   `json:"endedAt,omitempty"`
	Steps     []StepStatus `json:"steps"`
	Result    FlowResult   `json:"result"`
	Error     string       `json:"error,omitempty"`
}

type FlowState string

const (
	FlowStatePending   FlowState = "pending"
	FlowStateRunning   FlowState = "running"
	FlowStateCompleted FlowState = "completed"
	FlowStateFailed    FlowState = "failed"
	FlowStateCancelled FlowState = "cancelled"
)

type StepStatus struct {
	ID        string      `json:"id"`
	State     StepState   `json:"state"`
	StartedAt *time.Time  `json:"startedAt,omitempty"`
	EndedAt   *time.Time  `json:"endedAt,omitempty"`
	Output    interface{} `json:"output,omitempty"`
	Error     string      `json:"error,omitempty"`
}

type StepState string

const (
	StepStateWaiting   StepState = "waiting"
	StepStateRunning   StepState = "running"
	StepStateCompleted StepState = "completed"
	StepStateFailed    StepState = "failed"
	StepStateSkipped   StepState = "skipped"
)

type FlowResult struct {
	Summary string                 `json:"summary"`
	Data    map[string]interface{} `json:"data"`
}
