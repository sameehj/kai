package types

type Sensor struct {
	Kind       string         `yaml:"kind" json:"kind"`
	APIVersion string         `yaml:"apiVersion" json:"apiVersion"`
	Metadata   SensorMetadata `yaml:"metadata" json:"metadata"`
	Spec       SensorSpec     `yaml:"spec" json:"spec"`
}

type SensorMetadata struct {
	ID          string   `yaml:"id" json:"id"`
	Name        string   `yaml:"name" json:"name"`
	Description string   `yaml:"description" json:"description"`
	Tags        []string `yaml:"tags" json:"tags"`
}

type SensorSpec struct {
	Backend        string                 `yaml:"backend" json:"backend"` // kernel, system, k8s, cloud
	Type           string                 `yaml:"type" json:"type"`       // ebpf, cli, http
	Operation      string                 `yaml:"operation,omitempty" json:"operation,omitempty"`
	Command        []string               `yaml:"command,omitempty" json:"command,omitempty"`
	With           map[string]interface{} `yaml:"with,omitempty" json:"with,omitempty"`
	TimeoutSeconds int                    `yaml:"timeoutSeconds,omitempty" json:"timeoutSeconds,omitempty"`
	Params         map[string]ParamSchema `yaml:"params,omitempty" json:"params,omitempty"`
	Output         OutputSpec             `yaml:"output" json:"output"`
	Safety         SafetySpec             `yaml:"safety" json:"safety"`
}

type ParamSchema struct {
	Type        string      `yaml:"type" json:"type"`
	Description string      `yaml:"description,omitempty" json:"description,omitempty"`
	Default     interface{} `yaml:"default,omitempty" json:"default,omitempty"`
	Required    bool        `yaml:"required,omitempty" json:"required,omitempty"`
}

type OutputSpec struct {
	Format    string `yaml:"format" json:"format"`
	SchemaRef string `yaml:"schemaRef,omitempty" json:"schemaRef,omitempty"`
}

type SafetySpec struct {
	Mode string `yaml:"mode" json:"mode"` // read_only, write, privileged
	Risk string `yaml:"risk" json:"risk"` // low, medium, high
}
