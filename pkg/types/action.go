package types

type Action struct {
	Kind       string         `yaml:"kind" json:"kind"`
	APIVersion string         `yaml:"apiVersion" json:"apiVersion"`
	Metadata   ActionMetadata `yaml:"metadata" json:"metadata"`
	Spec       ActionSpec     `yaml:"spec" json:"spec"`
}

type ActionMetadata struct {
	ID          string   `yaml:"id" json:"id"`
	Name        string   `yaml:"name" json:"name"`
	Description string   `yaml:"description" json:"description"`
	Tags        []string `yaml:"tags" json:"tags"`
}

type ActionSpec struct {
	Backend   string                 `yaml:"backend" json:"backend"`
	Operation string                 `yaml:"operation" json:"operation"`
	Params    map[string]ParamSchema `yaml:"params" json:"params"`
	Safety    ActionSafety           `yaml:"safety" json:"safety"`
}

type ActionSafety struct {
	Mode             string `yaml:"mode" json:"mode"` // write, privileged
	Risk             string `yaml:"risk" json:"risk"` // low, medium, high, critical
	RequiresApproval bool   `yaml:"requiresApproval" json:"requiresApproval"`
}
