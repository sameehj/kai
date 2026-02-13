package tool

import (
	"context"
	"os"
	"strings"
)

type LsTool struct{}

func (t *LsTool) Name() string {
	return "ls"
}

func (t *LsTool) Description() string {
	return "List directory contents"
}

func (t *LsTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"path": map[string]string{"type": "string", "description": "Directory path"},
		},
		"required": []string{"path"},
	}
}

func (t *LsTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	path, _ := input["path"].(string)
	if path == "" {
		path = "."
	}
	path = expandPath(path)
	entries, err := os.ReadDir(path)
	if err != nil {
		return "", err
	}
	var out []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			name += string(os.PathSeparator)
		}
		out = append(out, name)
	}
	return strings.Join(out, "\n"), nil
}
