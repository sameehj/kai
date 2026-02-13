package workspace

import (
	"os"
	"path/filepath"
	"strings"
)

type PromptComponents struct {
	Base   string
	Soul   string
	Tools  string
	Skills []string
	Memory string
	Defs   string
}

func LoadPromptComponents(workspace string, skills []string) (*PromptComponents, error) {
	pc := &PromptComponents{}

	agentsPath := filepath.Join(workspace, AgentsFile)
	base, err := os.ReadFile(agentsPath)
	if err != nil {
		pc.Base = DefaultAgentsMD
	} else {
		pc.Base = string(base)
	}

	soulPath := filepath.Join(workspace, SoulFile)
	if soul, err := os.ReadFile(soulPath); err == nil {
		pc.Soul = string(soul)
	}

	toolsPath := filepath.Join(workspace, ToolsFile)
	if tools, err := os.ReadFile(toolsPath); err == nil {
		pc.Tools = string(tools)
	}

	for _, skillName := range skills {
		skillPath := filepath.Join(workspace, SkillsDir, skillName, "SKILL.md")
		if content, err := os.ReadFile(skillPath); err == nil {
			pc.Skills = append(pc.Skills, string(content))
		}
	}

	return pc, nil
}

func (pc *PromptComponents) Compose() string {
	var buf strings.Builder

	buf.WriteString(pc.Base)
	buf.WriteString("\n\n")

	if pc.Soul != "" {
		buf.WriteString("## Personality\n\n")
		buf.WriteString(pc.Soul)
		buf.WriteString("\n\n")
	}

	if pc.Tools != "" {
		buf.WriteString("## Tool Usage Conventions\n\n")
		buf.WriteString(pc.Tools)
		buf.WriteString("\n\n")
	}

	if pc.Defs != "" {
		buf.WriteString("## Tool Definitions\n\n")
		buf.WriteString(pc.Defs)
		buf.WriteString("\n\n")
	}

	if len(pc.Skills) > 0 {
		buf.WriteString("## Relevant Skills\n\n")
		for _, skill := range pc.Skills {
			buf.WriteString(skill)
			buf.WriteString("\n\n---\n\n")
		}
	}

	if pc.Memory != "" {
		buf.WriteString("## Relevant Memory\n\n")
		buf.WriteString(pc.Memory)
		buf.WriteString("\n\n")
	}

	return buf.String()
}
