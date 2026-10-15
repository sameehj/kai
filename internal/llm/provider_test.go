package llm

import (
	"os"
	"testing"

	"github.com/kai-agent/kai/internal/config"
)

func TestNewProviderCodexUsesEnvKey(t *testing.T) {
	_ = os.Setenv("CODEX_API_KEY", "k-test")
	defer os.Unsetenv("CODEX_API_KEY")

	p, err := NewProvider(config.LLMConfig{Provider: "codex", Model: ""})
	if err != nil {
		t.Fatalf("new provider: %v", err)
	}
	op, ok := p.(*OpenAIProvider)
	if !ok {
		t.Fatalf("expected OpenAIProvider for codex, got %T", p)
	}
	if op.cfg.APIKey != "k-test" {
		t.Fatalf("expected CODEX_API_KEY, got %q", op.cfg.APIKey)
	}
	if op.cfg.Model == "" {
		t.Fatal("expected default model for codex")
	}
}

func TestNewProviderAnthropicNormalizesLegacyModel(t *testing.T) {
	p, err := NewProvider(config.LLMConfig{
		Provider: "anthropic",
		Model:    "claude-sonnet-4-5-20250514",
		APIKey:   "k-test",
	})
	if err != nil {
		t.Fatalf("new provider: %v", err)
	}
	ap, ok := p.(*AnthropicProvider)
	if !ok {
		t.Fatalf("expected AnthropicProvider, got %T", p)
	}
	if ap.cfg.Model != "claude-3-5-sonnet-latest" {
		t.Fatalf("expected normalized model, got %q", ap.cfg.Model)
	}
}
