package tool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type ReadTool struct{}

func (t *ReadTool) Name() string {
	return "read"
}

func (t *ReadTool) Description() string {
	return "Read a file's contents"
}

func (t *ReadTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"path": map[string]string{"type": "string", "description": "File path"},
		},
		"required": []string{"path"},
	}
}

func (t *ReadTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	path, _ := input["path"].(string)
	if path == "" {
		return "", fmt.Errorf("path is required")
	}
	path = expandPath(path)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func expandPath(path string) string {
	if strings.HasPrefix(path, "~") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(path, "~"))
	}
	return path
}
