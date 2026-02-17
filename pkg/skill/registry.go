package skill

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Registry struct {
	baseDirs []string
}

func NewRegistry(workspace string) *Registry {
	baseDirs := []string{filepath.Join(workspace, "skills")}
	if home, err := os.UserHomeDir(); err == nil {
		baseDirs = append(baseDirs, filepath.Join(home, ".kai", "skills"))
	}
	return &Registry{baseDirs: baseDirs}
}

func (r *Registry) List() []string {
	seen := make(map[string]struct{})
	out := []string{}
	for _, base := range r.baseDirs {
		err := filepath.WalkDir(base, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				return nil
			}
			if d.Name() != "SKILL.md" {
				return nil
			}
			relDir, err := filepath.Rel(base, filepath.Dir(path))
			if err != nil {
				return nil
			}
			relDir = filepath.ToSlash(relDir)
			if relDir == "." || relDir == "" {
				return nil
			}
			if _, ok := seen[relDir]; ok {
				return nil
			}
			seen[relDir] = struct{}{}
			out = append(out, relDir)
			return nil
		})
		if err != nil {
			continue
		}
	}
	sort.Strings(out)
	return out
}

func (r *Registry) SelectRelevant(messages []string) []string {
	skills := r.List()
	if len(skills) == 0 || len(messages) == 0 {
		return nil
	}
	msgNorm := make([]string, 0, len(messages))
	msgTokens := make(map[string]struct{})
	for _, msg := range messages {
		nm := Normalize(msg)
		if nm == "" {
			continue
		}
		msgNorm = append(msgNorm, nm)
		for _, tok := range tokenize(nm) {
			msgTokens[tok] = struct{}{}
		}
	}
	var out []string
	for _, skill := range skills {
		path := r.SkillPath(skill)
		candidates := []string{skill, filepath.Base(skill)}
		if meta := readSkillMetadata(path); meta != "" {
			candidates = append(candidates, meta)
		}
		if matchAnyCandidate(msgNorm, msgTokens, candidates) {
			out = append(out, skill)
		}
	}
	return out
}

func (r *Registry) SkillPath(name string) string {
	for _, base := range r.baseDirs {
		path := filepath.Join(base, name, "SKILL.md")
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return filepath.Join(r.baseDirs[0], name, "SKILL.md")
}

func (r *Registry) Exists(name string) bool {
	path := r.SkillPath(name)
	if _, err := os.Stat(path); err == nil {
		return true
	}
	return false
}

func Normalize(name string) string {
	s := strings.ToLower(name)
	var b strings.Builder
	lastSpace := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastSpace = false
			continue
		}
		if !lastSpace {
			b.WriteByte(' ')
			lastSpace = true
		}
	}
	return strings.TrimSpace(b.String())
}

func readSkillMetadata(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	text := string(data)
	if !strings.HasPrefix(strings.TrimSpace(text), "---") {
		return ""
	}
	lines := strings.Split(text, "\n")
	inFrontmatter := false
	var parts []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "---" {
			if !inFrontmatter {
				inFrontmatter = true
				continue
			}
			break
		}
		if !inFrontmatter {
			continue
		}
		switch {
		case strings.HasPrefix(trimmed, "name:"):
			parts = append(parts, strings.TrimSpace(strings.TrimPrefix(trimmed, "name:")))
		case strings.HasPrefix(trimmed, "description:"):
			parts = append(parts, strings.TrimSpace(strings.TrimPrefix(trimmed, "description:")))
		}
	}
	return strings.Join(parts, " ")
}

func matchAnyCandidate(msgNorm []string, msgTokens map[string]struct{}, candidates []string) bool {
	for _, candidate := range candidates {
		needle := Normalize(candidate)
		if needle == "" {
			continue
		}
		for _, msg := range msgNorm {
			if strings.Contains(msg, needle) {
				return true
			}
		}
		cTokens := tokenize(needle)
		if len(cTokens) == 0 {
			continue
		}
		overlap := 0
		for _, tok := range cTokens {
			if _, ok := msgTokens[tok]; ok {
				overlap++
			}
		}
		threshold := 2
		if len(cTokens) >= 6 {
			threshold = 3
		}
		if overlap >= threshold {
			return true
		}
	}
	return false
}

func tokenize(s string) []string {
	fields := strings.Fields(Normalize(s))
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if len(f) < 3 {
			continue
		}
		if _, stop := stopWords[f]; stop {
			continue
		}
		out = append(out, f)
	}
	return out
}

var stopWords = map[string]struct{}{
	"and": {}, "are": {}, "can": {}, "for": {}, "how": {}, "its": {},
	"list": {}, "the": {}, "this": {}, "with": {}, "that": {}, "from": {},
}
