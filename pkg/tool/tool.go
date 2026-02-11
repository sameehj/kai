package tool

type Tool struct {
	Name        string
	Description string
	Path        string
	Metadata    ToolMetadata
	Content     string
}

type ToolMetadata struct {
	Name        string `yaml:"name" json:"name"`
	Description string `yaml:"description" json:"description"`
	Metadata    struct {
		Kai struct {
			Emoji    string   `yaml:"emoji" json:"emoji"`
			OS       []string `yaml:"os" json:"os"`
			Requires struct {
				Bins []string `yaml:"bins" json:"bins"`
			} `yaml:"requires" json:"requires"`
		} `yaml:"kai" json:"kai"`
	} `yaml:"metadata" json:"metadata"`
	Available bool   `yaml:"-" json:"available"`
	Reason    string `yaml:"-" json:"reason,omitempty"`
}
