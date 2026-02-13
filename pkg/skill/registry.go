package skill

import (
	"os"
	"path/filepath"
	"strings"
)

type Registry struct {
	baseDir string
}

func NewRegistry(workspace string) *Registry {
	return &Registry{baseDir: filepath.Join(workspace, "skills")}
}

func (r *Registry) List() []string {
	entries, err := os.ReadDir(r.baseDir)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, entry := range entries {
		if entry.IsDir() {
			out = append(out, entry.Name())
		}
	}
	return out
}

func (r *Registry) SelectRelevant(messages []string) []string {
	skills := r.List()
	if len(skills) == 0 || len(messages) == 0 {
		return nil
	}
	var out []string
	for _, skill := range skills {
		needle := Normalize(skill)
		for _, msg := range messages {
			if strings.Contains(Normalize(msg), needle) {
				out = append(out, skill)
				break
			}
		}
	}
	return out
}

func (r *Registry) SkillPath(name string) string {
	return filepath.Join(r.baseDir, name, "SKILL.md")
}

func (r *Registry) Exists(name string) bool {
	path := r.SkillPath(name)
	if _, err := os.Stat(path); err == nil {
		return true
	}
	return false
}

func Normalize(name string) string {
	return strings.TrimSpace(strings.ToLower(name))
}
