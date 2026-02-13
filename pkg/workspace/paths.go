package workspace

import (
	"os"
	"path/filepath"
)

const (
	AgentsFile = "AGENTS.md"
	SoulFile   = "SOUL.md"
	ToolsFile  = "TOOLS.md"
	SkillsDir  = "skills"
)

func Resolve() string {
	if ws := os.Getenv("KAI_WORKSPACE"); ws != "" {
		return ws
	}
	pwd, _ := os.Getwd()
	return pwd
}

func HomeDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".kai")
}
