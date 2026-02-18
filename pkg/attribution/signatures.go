package attribution

import "strings"

import "github.com/kai-ai/kai/pkg/models"

type AgentSignature struct {
	ID           models.AgentID
	ProcessNames []string
	DisplayName  string
}

var Signatures = []AgentSignature{
	{ID: models.AgentCursor, DisplayName: "Cursor", ProcessNames: []string{"Cursor", "cursor", "cursor-server"}},
	{ID: models.AgentClaude, DisplayName: "Claude Desktop", ProcessNames: []string{"Claude", "claude"}},
	{ID: models.AgentCodex, DisplayName: "Codex CLI", ProcessNames: []string{"codex"}},
	{ID: models.AgentCopilot, DisplayName: "GitHub Copilot", ProcessNames: []string{"Code", "code", "code-server"}},
	{ID: models.AgentOllama, DisplayName: "Ollama", ProcessNames: []string{"ollama"}},
	{ID: models.AgentLMStudio, DisplayName: "LM Studio", ProcessNames: []string{"LM Studio", "lm-studio"}},
}

var KnownAIDomains = map[string]models.AgentID{
	"api.anthropic.com":                   models.AgentClaude,
	"api.openai.com":                      models.AgentCodex,
	"chat.openai.com":                     models.AgentCodex,
	"chatgpt.com":                         models.AgentCodex,
	"openai.com":                          models.AgentCodex,
	"copilot-proxy.githubusercontent.com": models.AgentCopilot,
	"generativelanguage.googleapis.com":   models.AgentGemini,
	"api.cursor.so":                       models.AgentCursor,
	"api2.cursor.sh":                      models.AgentCursor,
	"localhost:11434":                     models.AgentOllama,
	"localhost:1234":                      models.AgentLMStudio,
}

func AgentForDomain(domain string) (models.AgentID, bool) {
	d := normalizeDomain(domain)
	for known, agent := range KnownAIDomains {
		k := normalizeDomain(known)
		if d == k || strings.HasSuffix(d, "."+k) {
			return agent, true
		}
	}
	return models.AgentUnknown, false
}

func normalizeDomain(v string) string {
	s := strings.ToLower(strings.TrimSpace(v))
	s = strings.TrimSuffix(s, ".")
	if i := strings.LastIndex(s, ":"); i >= 0 && !strings.Contains(s[i+1:], "]") {
		s = s[:i]
	}
	return s
}
