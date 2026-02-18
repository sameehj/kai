package attribution

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kai-ai/kai/pkg/models"
)

type RiskRule struct {
	Match func(event *models.AgentEvent) bool
	Score int
	Label string
}

var riskRules = []RiskRule{
	{Score: 90, Label: "force push", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && containsAll(e.Target, "git push", "--force")
	}},
	{Score: 65, Label: "git push", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && strings.Contains(strings.ToLower(e.Target), "git push")
	}},
	{Score: 60, Label: "CI pipeline modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.Contains(e.Target, ".github/workflows/")
	}},
	{Score: 55, Label: "git repo modified", Match: func(e *models.AgentEvent) bool { return isFileWrite(e) && strings.Contains(e.Target, ".git/") }},
	{Score: 55, Label: "infra config modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.Contains(strings.ToLower(e.Target), "terraform")
	}},
	{Score: 45, Label: "docker config modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.HasSuffix(strings.ToLower(e.Target), "dockerfile")
	}},
	{Score: 40, Label: "compose modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.Contains(strings.ToLower(e.Target), "docker-compose")
	}},
	{Score: 45, Label: "deps modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.HasSuffix(strings.ToLower(e.Target), "package.json")
	}},
	{Score: 90, Label: "SSH key modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && containsAny(strings.ToLower(e.Target), "id_rsa", "id_ed25519")
	}},
	{Score: 85, Label: "cert/key modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && hasExt(strings.ToLower(e.Target), ".pem", ".key")
	}},
	{Score: 80, Label: "env file modified", Match: func(e *models.AgentEvent) bool {
		return isFileWrite(e) && strings.Contains(strings.ToLower(e.Target), ".env")
	}},
	{Score: 70, Label: "recursive delete", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && containsAll(strings.ToLower(e.Target), "rm", "-rf")
	}},
	{Score: 60, Label: "home dir deletion", Match: func(e *models.AgentEvent) bool {
		if e.ActionType != models.ActionFileDelete {
			return false
		}
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return false
		}
		cleanTarget := filepath.Clean(e.Target)
		cleanHome := filepath.Clean(home)
		return cleanTarget == cleanHome || strings.HasPrefix(cleanTarget, cleanHome+string(filepath.Separator))
	}},
	{Score: 50, Label: "sudo escalation", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && strings.HasPrefix(strings.TrimSpace(strings.ToLower(e.Target)), "sudo ")
	}},
	{Score: 35, Label: "permission change", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && strings.HasPrefix(strings.TrimSpace(strings.ToLower(e.Target)), "chmod ")
	}},
	{Score: 30, Label: "curl/wget executed", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionExec && (strings.HasPrefix(strings.TrimSpace(strings.ToLower(e.Target)), "curl ") || strings.HasPrefix(strings.TrimSpace(strings.ToLower(e.Target)), "wget "))
	}},
	{Score: 25, Label: "external network", Match: func(e *models.AgentEvent) bool {
		return e.ActionType == models.ActionNetConnect && !strings.Contains(e.Target, "127.0.0.1") && !strings.Contains(e.Target, "localhost")
	}},
}

var (
	riskMu          sync.Mutex
	recentFileOpsBy = map[models.AgentID][]time.Time{}
)

func ScoreEvent(event *models.AgentEvent) (int, []string) {
	total := 0
	labels := []string{}
	for _, rule := range riskRules {
		if rule.Match(event) {
			total += rule.Score
			labels = append(labels, rule.Label)
		}
	}
	if massFileOperation(event) {
		total += 55
		labels = append(labels, "mass file operation")
	}
	if total > 100 {
		total = 100
	}
	return total, labels
}

func isFileWrite(e *models.AgentEvent) bool {
	return e.ActionType == models.ActionFileWrite || e.ActionType == models.ActionFileCreate || e.ActionType == models.ActionFileDelete
}

func containsAll(s string, needles ...string) bool {
	for _, n := range needles {
		if !strings.Contains(strings.ToLower(s), strings.ToLower(n)) {
			return false
		}
	}
	return true
}

func containsAny(s string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(s, n) {
			return true
		}
	}
	return false
}

func hasExt(s string, exts ...string) bool {
	for _, ext := range exts {
		if strings.HasSuffix(s, ext) {
			return true
		}
	}
	return false
}

func massFileOperation(e *models.AgentEvent) bool {
	if !(e.ActionType == models.ActionFileWrite || e.ActionType == models.ActionFileCreate || e.ActionType == models.ActionFileDelete) {
		return false
	}
	riskMu.Lock()
	defer riskMu.Unlock()
	now := e.Timestamp
	threshold := now.Add(-5 * time.Second)
	events := recentFileOpsBy[e.Agent]
	kept := events[:0]
	for _, t := range events {
		if t.After(threshold) {
			kept = append(kept, t)
		}
	}
	kept = append(kept, now)
	recentFileOpsBy[e.Agent] = kept
	return len(kept) > 20
}
