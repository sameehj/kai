package main

import "testing"

func TestSelectLLMClientPrefersOpenAI(t *testing.T) {
	t.Setenv("KAI_PROVIDER", "")
	t.Setenv("OPENAI_API_KEY", "ok")
	t.Setenv("ANTHROPIC_API_KEY", "nope")
	if selectLLMClient() == nil {
		t.Fatalf("expected non-nil client when OPENAI_API_KEY is set")
	}
}

func TestSelectLLMClientExplicitAnthropic(t *testing.T) {
	t.Setenv("KAI_PROVIDER", "anthropic")
	t.Setenv("OPENAI_API_KEY", "ok")
	t.Setenv("ANTHROPIC_API_KEY", "ok")
	if selectLLMClient() == nil {
		t.Fatalf("expected anthropic client when provider is anthropic")
	}
}

func TestSelectLLMClientNone(t *testing.T) {
	t.Setenv("KAI_PROVIDER", "")
	t.Setenv("OPENAI_API_KEY", "")
	t.Setenv("ANTHROPIC_API_KEY", "")
	if selectLLMClient() != nil {
		t.Fatalf("expected nil client when no API keys are set")
	}
}
