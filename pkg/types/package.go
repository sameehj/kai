package types

import "time"

// Package represents a serialized package manifest used to install eBPF programs.
type Package struct {
	APIVersion   string       `yaml:"apiVersion"`
	Kind         string       `yaml:"kind"`
	Metadata     Metadata     `yaml:"metadata"`
	Build        Build        `yaml:"build"`
	Requirements Requirements `yaml:"requirements"`
	Interface    Interface    `yaml:"interface"`
	Policy       Policy       `yaml:"policy"`
}

type Metadata struct {
	Name        string   `yaml:"name"`
	Version     string   `yaml:"version"`
	Description string   `yaml:"description"`
	Upstream    Upstream `yaml:"upstream"`
	Author      string   `yaml:"author"`
	License     string   `yaml:"license"`
}

type Upstream struct {
	Repo   string `yaml:"repo"`
	Tag    string `yaml:"tag"`
	Commit string `yaml:"commit"`
}

type Build struct {
	Commands  []string  `yaml:"commands"`
	Output    []string  `yaml:"output"`
	Artifacts Artifacts `yaml:"artifacts"`
}

type Artifacts struct {
	Checksum string    `yaml:"checksum"`
	BuiltAt  time.Time `yaml:"built_at"`
}

type Requirements struct {
	Kernel       KernelRequirements `yaml:"kernel"`
	Capabilities []string           `yaml:"capabilities"`
}

type KernelRequirements struct {
	MinVersion string   `yaml:"min_version"`
	Features   []string `yaml:"features"`
	Helpers    []string `yaml:"helpers"`
}

type Interface struct {
	Programs   []ProgramDef   `yaml:"programs"`
	Maps       []MapDef       `yaml:"maps"`
	Chain      ChainDef       `yaml:"chain"`
	Output     OutputDef      `yaml:"output"`
	Parameters []ParameterDef `yaml:"parameters"`
}

type ProgramDef struct {
	Name     string `yaml:"name"`
	ID       string `yaml:"id"`
	File     string `yaml:"file"`
	Section  string `yaml:"section"`
	Type     string `yaml:"type"`
	AttachTo string `yaml:"attach_to"`
}

type MapDef struct {
	Name       string                 `yaml:"name"`
	Type       string                 `yaml:"type"`
	Purpose    string                 `yaml:"purpose"`
	MaxEntries uint32                 `yaml:"max_entries"`
	Pin        string                 `yaml:"pin"`
	Schema     SchemaDef              `yaml:"schema"`
	Defaults   map[string]interface{} `yaml:"defaults"`
}

type SchemaDef struct {
	Type      string     `yaml:"type"`
	Name      string     `yaml:"name,omitempty"`
	Fields    []FieldDef `yaml:"fields,omitempty"`
	KeyType   string     `yaml:"key_type,omitempty"`
	ValueType string     `yaml:"value_type,omitempty"`
}

type FieldDef struct {
	Name        string `yaml:"name"`
	Type        string `yaml:"type"`
	Description string `yaml:"description"`
}

type ChainDef struct {
	Entry     string     `yaml:"entry"`
	ProgArray string     `yaml:"prog_array"`
	Stages    []StageDef `yaml:"stages"`
}

type StageDef struct {
	ID       string `yaml:"id"`
	Index    uint32 `yaml:"index"`
	Next     string `yaml:"next,omitempty"`
	Terminal bool   `yaml:"terminal,omitempty"`
}

type OutputDef struct {
	Type        string `yaml:"type"`
	Map         string `yaml:"map"`
	Format      string `yaml:"format"`
	SampleEvent string `yaml:"sample_event"`
}

type ParameterDef struct {
	Name        string      `yaml:"name"`
	Type        string      `yaml:"type"`
	Description string      `yaml:"description"`
	Map         string      `yaml:"map"`
	MapKey      interface{} `yaml:"map_key"`
	Default     interface{} `yaml:"default"`
	Optional    bool        `yaml:"optional"`
}

type Policy struct {
	AttachPoints AttachPointsPolicy `yaml:"attach_points"`
	Namespaces   NamespacesPolicy   `yaml:"namespaces"`
	RateLimits   RateLimitsPolicy   `yaml:"rate_limits"`
}

type AttachPointsPolicy struct {
	Allowed []string `yaml:"allowed"`
	Denied  []string `yaml:"denied"`
}

type NamespacesPolicy struct {
	Scope         string `yaml:"scope"`
	DefaultFilter bool   `yaml:"default_filter"`
}

type RateLimitsPolicy struct {
	EventsPerSec  uint32 `yaml:"events_per_sec"`
	MaxMapEntries uint32 `yaml:"max_map_entries"`
}
