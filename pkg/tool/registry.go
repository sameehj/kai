package tool

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/sameehj/kai/pkg/system"
	"gopkg.in/yaml.v3"
)

type Registry struct {
	paths   []string
	profile *system.Profile
	tools   map[string]*Tool
}

func NewRegistry(paths []string, profile *system.Profile) *Registry {
	expanded := make([]string, 0, len(paths))
	for _, p := range paths {
		if p == "" {
			continue
		}
		expanded = append(expanded, expandPath(p))
	}
	return &Registry{paths: expanded, profile: profile, tools: make(map[string]*Tool)}
}

func (r *Registry) Load() error {
	r.tools = make(map[string]*Tool)
	for _, base := range r.paths {
		if base == "" {
			continue
		}
		if err := r.loadPath(base); err != nil {
			return err
		}
	}
	return nil
}

func (r *Registry) loadPath(base string) error {
	info, err := os.Stat(base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("tools path is not a directory: %s", base)
	}

	entries, err := os.ReadDir(base)
	if err != nil {
		return err
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		toolPath := filepath.Join(base, entry.Name())
		tool, err := r.loadTool(toolPath)
		if err != nil {
			return err
		}
		if tool != nil {
			r.tools[tool.Name] = tool
		}
	}
	return nil
}

func (r *Registry) loadTool(path string) (*Tool, error) {
	toolMDPath := filepath.Join(path, "TOOL.md")
	content, err := os.ReadFile(toolMDPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	meta, desc, err := parseToolMarkdown(string(content))
	if err != nil {
		return nil, fmt.Errorf("parse TOOL.md in %s: %w", path, err)
	}

	name := meta.Name
	if name == "" {
		name = filepath.Base(path)
	}
	if desc == "" {
		desc = meta.Description
	}

	tool := &Tool{
		Name:        name,
		Description: desc,
		Path:        path,
		Metadata:    meta,
		Content:     string(content),
	}

	r.applyAvailability(tool)
	return tool, nil
}

func (r *Registry) applyAvailability(tool *Tool) {
	if r.profile == nil {
		tool.Metadata.Available = true
		return
	}

	if len(tool.Metadata.Metadata.Kai.OS) > 0 {
		ok := false
		for _, d := range tool.Metadata.Metadata.Kai.OS {
			if strings.EqualFold(d, r.profile.Distro) || strings.EqualFold(d, r.profile.OS) {
				ok = true
				break
			}
		}
		if !ok {
			tool.Metadata.Available = false
			tool.Metadata.Reason = "os mismatch"
			return
		}
	}

	if len(tool.Metadata.Metadata.Kai.Requires.Bins) > 0 {
		missing := r.profile.MissingBins(tool.Metadata.Metadata.Kai.Requires.Bins)
		if len(missing) > 0 {
			tool.Metadata.Available = false
			tool.Metadata.Reason = "missing bins: " + strings.Join(missing, ", ")
			return
		}
	}

	tool.Metadata.Available = true
}

func (r *Registry) List() []*Tool {
	tools := make([]*Tool, 0, len(r.tools))
	for _, tool := range r.tools {
		tools = append(tools, tool)
	}
	return tools
}

func (r *Registry) Get(name string) (*Tool, bool) {
	tool, ok := r.tools[name]
	return tool, ok
}

func (r *Registry) Create(name, content string) (*Tool, error) {
	if name == "" {
		return nil, errors.New("name is required")
	}
	if len(r.paths) == 0 {
		return nil, errors.New("no tools path configured")
	}

	base := r.paths[len(r.paths)-1]
	toolPath := filepath.Join(base, name)
	if err := os.MkdirAll(toolPath, 0o755); err != nil {
		return nil, err
	}

	toolMD := filepath.Join(toolPath, "TOOL.md")
	if _, err := os.Stat(toolMD); err == nil {
		return nil, fmt.Errorf("tool already exists: %s", name)
	}

	if content == "" {
		content = defaultToolMarkdown(name)
	}
	if err := os.WriteFile(toolMD, []byte(content), 0o644); err != nil {
		return nil, err
	}

	tool, err := r.loadTool(toolPath)
	if err != nil {
		return nil, err
	}
	if tool != nil {
		r.tools[tool.Name] = tool
	}
	return tool, nil
}

func (r *Registry) ReloadTool(path string) error {
	tool, err := r.loadTool(path)
	if err != nil {
		return err
	}
	if tool != nil {
		r.tools[tool.Name] = tool
	}
	return nil
}

func parseToolMarkdown(content string) (ToolMetadata, string, error) {
	meta := ToolMetadata{}
	trimmed := strings.TrimSpace(content)
	if strings.HasPrefix(trimmed, "---") {
		parts := strings.SplitN(trimmed, "---", 3)
		if len(parts) < 3 {
			return meta, "", errors.New("invalid frontmatter")
		}
		front := strings.TrimSpace(parts[1])
		body := strings.TrimSpace(parts[2])
		if err := yaml.Unmarshal([]byte(front), &meta); err != nil {
			return meta, "", err
		}
		desc := firstDescription(body)
		return meta, desc, nil
	}

	return meta, firstDescription(content), nil
}

func firstDescription(content string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		return line
	}
	return ""
}

func defaultToolMarkdown(name string) string {
	return fmt.Sprintf("# %s\n\nDescribe the tool here.\n", name)
}

func expandPath(path string) string {
	if strings.HasPrefix(path, "~") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	return path
}
