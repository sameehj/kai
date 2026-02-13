package tool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type SearchTool struct{}

func (t *SearchTool) Name() string {
	return "search"
}

func (t *SearchTool) Description() string {
	return "Search file contents for a string"
}

func (t *SearchTool) Schema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object",
		"properties": map[string]interface{}{
			"path":  map[string]string{"type": "string", "description": "Root path"},
			"query": map[string]string{"type": "string", "description": "Search query"},
		},
		"required": []string{"path", "query"},
	}
}

func (t *SearchTool) Execute(ctx context.Context, input map[string]interface{}) (string, error) {
	path, _ := input["path"].(string)
	query, _ := input["query"].(string)
	if path == "" || query == "" {
		return "", fmt.Errorf("path and query are required")
	}
	path = expandPath(path)
	matches := []string{}
	err := filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		if strings.Contains(string(data), query) {
			matches = append(matches, p)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return strings.Join(matches, "\n"), nil
}
