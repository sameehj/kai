package tool

import (
	"context"
	"fmt"
	"os"
	"strings"
)

type ReplaceTool struct{}

func (t *ReplaceTool) Name() string {
	return "replace"
}

func (t *ReplaceTool) Description() string {
	return "Find and replace text in a file"
}

func (t *ReplaceTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"path":    map[string]string{"type": "string", "description": "File path"},
			"find":    map[string]string{"type": "string", "description": "Text to find"},
			"replace": map[string]string{"type": "string", "description": "Replacement text"},
		},
		"required": []string{"path", "find", "replace"},
	}
}

func (t *ReplaceTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	path, _ := input["path"].(string)
	find, _ := input["find"].(string)
	repl, _ := input["replace"].(string)
	if path == "" || find == "" {
		return "", fmt.Errorf("path and find are required")
	}
	path = expandPath(path)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	updated := strings.ReplaceAll(string(data), find, repl)
	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return "", err
	}
	return "updated", nil
}
