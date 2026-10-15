package skills

import (
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/executor"
)

type Metadata struct {
	Name           string
	Version        string
	Description    string
	Category       string
	Author         string
	RequiresRoot   string
	KernelMin      string
	RequiredBins   []string
	CommonCommands []string
}

type Skill struct {
	Name        string
	Metadata    Metadata
	Content     string
	Available   bool
	Degraded    bool
	MissingDeps []string
	Path        string
}

func LoadSkills(skillRoots []string, probe *executor.ProbeResult, disabled []string) ([]Skill, error) {
	dis := map[string]bool{}
	for _, d := range disabled {
		dis[strings.TrimSpace(d)] = true
	}
	all := map[string]Skill{}
	for _, root := range skillRoots {
		if strings.TrimSpace(root) == "" {
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			dir := filepath.Join(root, e.Name())
			metaPath := filepath.Join(dir, "metadata.yaml")
			if _, err := os.Stat(metaPath); err != nil {
				// For MVP we only load skills that have explicit metadata.yaml.
				continue
			}
			meta := parseMetadata(metaPath)
			if meta.Name == "" {
				meta.Name = e.Name()
			}
			if strings.TrimSpace(meta.Description) == "" {
				// Skip stub skills without a useful description.
				continue
			}
			if dis[meta.Name] {
				continue
			}
			content, _ := os.ReadFile(filepath.Join(dir, "SKILL.md"))
			if len(strings.TrimSpace(string(content))) < 80 {
				continue
			}
			sk := Skill{Name: meta.Name, Metadata: meta, Content: string(content), Path: filepath.Join(dir, "SKILL.md")}
			sk.Available, sk.Degraded, sk.MissingDeps = checkAvailability(meta, probe)
			all[sk.Name] = sk
		}
	}
	out := make([]Skill, 0, len(all))
	for _, s := range all {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func LoadAllSkills(probe *executor.ProbeResult, disabled []string, extraRoots []string) ([]Skill, error) {
	roots := []string{
		config.BundledSkillRoot(),
		filepath.Join(filepath.Dir(config.BundledSkillRoot()), "..", "skills"), // e.g. repo root when binary is in bin/
		"skills", // cwd fallback for dev runs
		config.DefaultSkillRoot(),
		config.DefaultCommunitySkillRoot(),
	}
	roots = append(roots, extraRoots...)
	roots = dedupeRoots(roots)
	loaded, err := LoadSkills(roots, probe, disabled)
	if err != nil {
		// Community skill loading should not break startup.
		log.Printf("warning: loading skills: %v", err)
		return LoadSkills([]string{config.BundledSkillRoot(), "skills", config.DefaultSkillRoot()}, probe, disabled)
	}
	return loaded, nil
}

func dedupeRoots(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
	for _, root := range in {
		root = strings.TrimSpace(root)
		if root == "" {
			continue
		}
		clean := filepath.Clean(root)
		if _, ok := seen[clean]; ok {
			continue
		}
		seen[clean] = struct{}{}
		out = append(out, clean)
	}
	return out
}
