package types

// Flow represents a multi-step investigation or remediation workflow.
type Flow struct {
	Kind       string       `yaml:"kind" json:"kind"`
	APIVersion string       `yaml:"apiVersion" json:"apiVersion"`
	Metadata   FlowMetadata `yaml:"metadata" json:"metadata"`
	Spec       FlowSpec     `yaml:"spec" json:"spec"`
}

type FlowMetadata struct {
	ID          string              `yaml:"id" json:"id"`
	Name        string              `yaml:"name" json:"name"`
	Description string              `yaml:"description" json:"description"`
	Tags        []string            `yaml:"tags" json:"tags"`
	References  []FlowReferenceMeta `yaml:"references,omitempty" json:"references,omitempty"`
}

type FlowReferenceMeta struct {
	Title string `yaml:"title" json:"title"`
	URL   string `yaml:"url" json:"url"`
}

type FlowSpec struct {
	Triggers []Trigger  `yaml:"triggers" json:"triggers"`
	Steps    []FlowStep `yaml:"steps" json:"steps"`
}

type Trigger struct {
	Type      string                 `yaml:"type" json:"type"`
	Source    string                 `yaml:"source" json:"source"`
	Metric    string                 `yaml:"metric" json:"metric"`
	Condition string                 `yaml:"condition" json:"condition"`
	Window    string                 `yaml:"window" json:"window"`
	Config    map[string]interface{} `yaml:"config" json:"config"`
}

type FlowStep struct {
	ID        string                 `yaml:"id" json:"id"`
	Type      string                 `yaml:"type" json:"type"` // sensor, agent, action, memory_search
	Ref       string                 `yaml:"ref,omitempty" json:"ref,omitempty"`
	AgentType string                 `yaml:"agentType,omitempty" json:"agentType,omitempty"`
	DependsOn []string               `yaml:"dependsOn,omitempty" json:"dependsOn,omitempty"`
	Condition string                 `yaml:"condition,omitempty" json:"condition,omitempty"`
	Timeout   string                 `yaml:"timeout,omitempty" json:"timeout,omitempty"`
	With      map[string]interface{} `yaml:"with,omitempty" json:"with,omitempty"`
	Input     []StepInput            `yaml:"input,omitempty" json:"input,omitempty"`
	Output    StepOutput             `yaml:"output,omitempty" json:"output,omitempty"`
}

type StepInput struct {
	FromStep string `yaml:"fromStep" json:"fromStep"`
}

type StepOutput struct {
	SaveAs string `yaml:"saveAs" json:"saveAs"`
}
