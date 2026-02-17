package llm

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenAIBearerFromCodexAuthPathPrefersAPIKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "auth.json")
	content := `{
  "OPENAI_API_KEY": "sk-test",
  "tokens": {"access_token": "at-test"}
}`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write auth file: %v", err)
	}
	got, err := openAIBearerFromCodexAuthPath(path)
	if err != nil {
		t.Fatalf("openAIBearerFromCodexAuthPath: %v", err)
	}
	if got != "sk-test" {
		t.Fatalf("expected api key, got %q", got)
	}
}

func TestOpenAIBearerFromCodexAuthPathFallsBackToAccessToken(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "auth.json")
	content := `{
  "OPENAI_API_KEY": null,
  "tokens": {"access_token": "at-test"}
}`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write auth file: %v", err)
	}
	got, err := openAIBearerFromCodexAuthPath(path)
	if err != nil {
		t.Fatalf("openAIBearerFromCodexAuthPath: %v", err)
	}
	if got != "at-test" {
		t.Fatalf("expected access token fallback, got %q", got)
	}
}
