package attribution

import (
	"testing"

	"github.com/kai-ai/kai/pkg/models"
)

func TestAgentForDomainSuffix(t *testing.T) {
	cases := []struct {
		domain string
		want   models.AgentID
	}{
		{"chatgpt.com", models.AgentCodex},
		{"chat.openai.com", models.AgentCodex},
		{"api.anthropic.com", models.AgentClaude},
		{"sub.chatgpt.com", models.AgentCodex},
	}
	for _, tc := range cases {
		got, ok := AgentForDomain(tc.domain)
		if !ok {
			t.Fatalf("expected domain %s to match", tc.domain)
		}
		if got != tc.want {
			t.Fatalf("domain %s expected %s got %s", tc.domain, tc.want, got)
		}
	}
}
