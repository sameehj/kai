package tool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

type WriteTool struct{}

func (t *WriteTool) Name() string {
	return "write"
}

func (t *WriteTool) Description() string {
	return "Write content to a file"
}

func (t *WriteTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"path":    map[string]string{"type": "string", "description": "File path"},
			"content": map[string]string{"type": "string", "description": "Content to write"},
		},
		"required": []string{"path", "content"},
	}
}

func (t *WriteTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	path, _ := input["path"].(string)
	content, _ := input["content"].(string)
	if path == "" {
		return "", fmt.Errorf("path is required")
	}
	path = expandPath(path)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return "", err
	}
	return fmt.Sprintf("wrote %d bytes", len(content)), nil
}
