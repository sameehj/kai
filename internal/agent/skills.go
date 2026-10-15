package agent

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type Skill struct {
	Name        string
	Description string
	Path        string
	Source      string
	RequiresBin []string
	Available   bool
	Reason      string
}

type SkillStore struct {
	userRoots []string
	bundled   string
	disabled  map[string]bool
}

func NewSkillStore(userRoots []string, bundled string, disabled []string) *SkillStore {
	dis := make(map[string]bool, len(disabled))
	for _, d := range disabled {
		dis[strings.TrimSpace(d)] = true
	}
	return &SkillStore{userRoots: userRoots, bundled: bundled, disabled: dis}
}

func (s *SkillStore) Load() ([]Skill, error) {
	all := map[string]Skill{}
	if s.bundled != "" {
		bundled, err := loadSkillDir(s.bundled, "bundled", s.disabled)
		if err != nil {
			return nil, err
		}
		for _, sk := range bundled {
			all[sk.Name] = sk
		}
	}
	for _, root := range s.userRoots {
		if strings.TrimSpace(root) == "" {
			continue
		}
		userSkills, err := loadSkillDir(root, "user", s.disabled)
		if err != nil {
			return nil, err
		}
		for _, sk := range userSkills {
			all[sk.Name] = sk
		}
	}

	out := make([]Skill, 0, len(all))
	for _, sk := range all {
		sk.Available = true
		for _, bin := range sk.RequiresBin {
			if _, err := exec.LookPath(bin); err != nil {
				sk.Available = false
				sk.Reason = "missing required binary: " + bin
				break
			}
		}
		out = append(out, sk)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func loadSkillDir(root, source string, disabled map[string]bool) ([]Skill, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read skills dir %s: %w", root, err)
	}
	out := make([]Skill, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		path := filepath.Join(root, e.Name(), "SKILL.md")
		sk := parseSkillFrontmatter(path)
		if sk.Name == "" {
			sk.Name = e.Name()
		}
		if disabled[sk.Name] {
			continue
		}
		sk.Path = path
		sk.Source = source
		out = append(out, sk)
	}
	return out, nil
}

func parseSkillFrontmatter(path string) Skill {
	f, err := os.Open(path)
	if err != nil {
		return Skill{}
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	in := false
	meta := Skill{}
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "---" && !in {
			in = true
			continue
		}
		if line == "---" && in {
			break
		}
		if !in {
			break
		}
		if v, ok := strings.CutPrefix(line, "name:"); ok {
			meta.Name = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "description:"); ok {
			meta.Description = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "bins:"); ok {
			for _, p := range strings.Split(strings.Trim(v, " []"), ",") {
				b := strings.Trim(strings.TrimSpace(p), "\"")
				if b != "" {
					meta.RequiresBin = append(meta.RequiresBin, b)
				}
			}
		}
	}
	return meta
}

func SkillsAsXML(skills []Skill) string {
	if len(skills) == 0 {
		return "<available_skills></available_skills>"
	}
	lines := []string{"<available_skills>"}
	for _, s := range skills {
		avail := "true"
		note := ""
		if !s.Available {
			avail = "false"
			note = fmt.Sprintf(" note=\"%s\"", xmlEscape(s.Reason))
		}
		lines = append(lines, fmt.Sprintf("  <skill name=\"%s\" description=\"%s\" location=\"%s\" source=\"%s\" available=\"%s\"%s />", xmlEscape(s.Name), xmlEscape(s.Description), xmlEscape(s.Path), xmlEscape(s.Source), avail, note))
	}
	lines = append(lines, "</available_skills>")
	return strings.Join(lines, "\n")
}

func xmlEscape(s string) string {
	r := strings.ReplaceAll(s, "&", "&amp;")
	r = strings.ReplaceAll(r, "<", "&lt;")
	r = strings.ReplaceAll(r, ">", "&gt;")
	r = strings.ReplaceAll(r, `"`, "&quot;")
	return r
}
