package policy

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/kai-agent/kai/internal/config"
)

type Decision int

const (
	Allow Decision = iota
	Confirm
	Block
)

type Result struct {
	Decision       Decision
	Reason         string
	Classification Classification
}

type Policy struct {
	Mode      string
	AllowSudo bool
	allow     []string
	confirm   []string
	block     []string
}

func New(cfg config.PolicyConfig) (*Policy, error) {
	if cfg.DefaultMode == "" {
		cfg.DefaultMode = cfg.Mode
	}
	if cfg.DefaultMode == "" {
		cfg.DefaultMode = "confirm"
	}
	if len(cfg.Block) == 0 && len(cfg.Blocked) > 0 {
		cfg.Block = append([]string{}, cfg.Blocked...)
	}
	if len(cfg.Confirm) == 0 && len(cfg.ConfirmRequired) > 0 {
		cfg.Confirm = append([]string{}, cfg.ConfirmRequired...)
	}
	if len(cfg.Allow) == 0 && len(cfg.AutoApprove) > 0 {
		cfg.Allow = append([]string{}, cfg.AutoApprove...)
	}
	return &Policy{Mode: strings.ToLower(strings.TrimSpace(cfg.DefaultMode)), AllowSudo: cfg.AllowSudo, allow: cfg.Allow, confirm: cfg.Confirm, block: cfg.Block}, nil
}

func (p *Policy) Check(toolName string, args json.RawMessage) Result {
	cmd := strings.TrimSpace(extractCommand(toolName, args))
	return p.CheckCommand(cmd)
}

func (p *Policy) CheckCommand(cmd string) Result {
	lcmd := strings.ToLower(strings.TrimSpace(cmd))

	for _, pat := range p.block {
		if matchPattern(pat, lcmd) {
			return Result{Decision: Block, Reason: "blocked by policy", Classification: Classification{Level: Dangerous, Reason: "blocklist"}}
		}
	}

	c := ClassifyCommand(lcmd)
	if c.Level == Dangerous {
		return Result{Decision: Block, Reason: c.Reason, Classification: c}
	}
	if c.Level == Moderate {
		return Result{Decision: Confirm, Reason: c.Reason, Classification: c}
	}

	for _, pat := range p.allow {
		if matchPattern(pat, lcmd) {
			return Result{Decision: Allow, Reason: "allowlist", Classification: c}
		}
	}
	for _, pat := range p.confirm {
		if matchPattern(pat, lcmd) {
			return Result{Decision: Confirm, Reason: "confirmation rule", Classification: c}
		}
	}

	switch p.Mode {
	case "readonly":
		return Result{Decision: Block, Reason: "readonly mode", Classification: c}
	case "allow":
		return Result{Decision: Allow, Reason: "default allow", Classification: c}
	default:
		return Result{Decision: Confirm, Reason: "default confirm mode", Classification: c}
	}
}

func extractCommand(toolName string, args json.RawMessage) string {
	if len(args) == 0 {
		return toolName
	}
	var m map[string]any
	if err := json.Unmarshal(args, &m); err != nil {
		return toolName
	}
	switch toolName {
	case "exec":
		if v, ok := m["command"].(string); ok {
			if sudo, _ := m["sudo"].(bool); sudo {
				return "sudo " + v
			}
			return v
		}
	case "write":
		if v, ok := m["path"].(string); ok {
			return "write " + v
		}
	case "read":
		if v, ok := m["path"].(string); ok {
			return "read " + v
		}
	case "search":
		if q, ok := m["query"].(string); ok {
			return "search " + q
		}
	}
	return fmt.Sprintf("%s %s", toolName, strings.ToLower(strings.TrimSpace(string(args))))
}

func matchPattern(pattern, text string) bool {
	pattern = strings.ToLower(strings.TrimSpace(pattern))
	if pattern == "" {
		return false
	}
	if strings.Contains(pattern, "*") {
		ok, _ := filepath.Match(pattern, text)
		if ok {
			return true
		}
	}
	return strings.Contains(text, strings.Trim(pattern, "*"))
}
