package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/evidence"
	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/llm"
	"github.com/kai-agent/kai/internal/policy"
	"github.com/kai-agent/kai/internal/skills"
	"github.com/kai-agent/kai/internal/tools"
)

type StreamEventType string

const (
	EventToolCall   StreamEventType = "tool_call"
	EventToolResult StreamEventType = "tool_result"
	EventTextDelta  StreamEventType = "text_delta"
	EventDone       StreamEventType = "done"
)

type StreamEvent struct {
	Type     StreamEventType
	Summary  string
	Text     string
	ExitCode *int
}

type StreamCallback func(StreamEvent)

type Agent struct {
	provider      llm.Provider
	tools         *tools.Registry
	session       *Session
	memory        *MemoryStore
	exec          executor.Executor
	policy        *policy.Policy
	reporter      channels.Dispatcher
	identityPath  string
	soulPath      string
	skills        []skills.Skill
	target        string
	probe         *executor.ProbeResult
	runRoot       string
	notify        string
	skillEnabled  []string
	skillDisabled []string
	skillDirs     []string
}

func New(cfg *config.Config) (*Agent, error) {
	return NewForTarget(cfg, config.DefaultTargetName(cfg.Targets))
}

func NewForTarget(cfg *config.Config, targetName string) (*Agent, error) {
	if cfg == nil {
		cfg = config.DefaultConfig()
	}
	if targetName == "" {
		targetName = config.DefaultTargetName(cfg.Targets)
	}
	t := cfg.Targets[targetName]
	exec, err := executor.BuildExecutor(executor.TargetSpec{Type: t.Type, Host: t.Host, Port: t.Port, User: t.User, KeyFile: t.Key, Container: t.Container})
	if err != nil {
		return nil, fmt.Errorf("build executor: %w", err)
	}
	provider, err := llm.NewProvider(cfg.LLM)
	if err != nil {
		return nil, fmt.Errorf("build provider: %w", err)
	}
	reg := tools.NewRegistry()
	tools.RegisterBuiltins(reg)
	sess, err := OpenSession(config.DefaultSessionPath())
	if err != nil {
		return nil, fmt.Errorf("open session: %w", err)
	}
	pol, err := policy.New(cfg.Policy)
	if err != nil {
		sess.Close()
		return nil, err
	}
	probe, _ := executor.Probe(context.Background(), exec)
	sk, _ := loadEnabledSkills(probe, cfg.Skills.Enabled, cfg.Skills.Disabled, cfg.Skills.Dirs)

	dispatcher := &channels.MultiDispatcher{Default: &channels.CLIChannel{}}
	if cfg.Channels.Slack.Enabled {
		dispatcher.Slack = &channels.SlackChannel{WebhookURL: cfg.Channels.Slack.WebhookURL}
	}
	if cfg.Channels.Telegram.Enabled {
		dispatcher.TG = &channels.TelegramChannel{BotToken: cfg.Channels.Telegram.BotToken}
	}
	if cfg.Channels.Email.Enabled {
		dispatcher.Email = &channels.EmailChannel{SMTPHost: cfg.Channels.Email.SMTPHost}
	}

	return &Agent{
		provider:      provider,
		tools:         reg,
		session:       sess,
		memory:        NewMemoryStore(config.DefaultMemoryFilePath(), config.DefaultDailyMemoryRoot()),
		exec:          exec,
		policy:        pol,
		reporter:      dispatcher,
		identityPath:  config.DefaultIdentityPath(),
		soulPath:      config.DefaultSoulPath(),
		skills:        sk,
		target:        targetName,
		probe:         probe,
		runRoot:       cfg.Evidence.Dir,
		skillEnabled:  append([]string{}, cfg.Skills.Enabled...),
		skillDisabled: append([]string{}, cfg.Skills.Disabled...),
		skillDirs:     append([]string{}, cfg.Skills.Dirs...),
	}, nil
}

func (a *Agent) SetNotifyChannel(channel string) {
	a.notify = strings.TrimSpace(channel)
}

func (a *Agent) Close() error {
	if a.session == nil {
		return nil
	}
	return a.session.Close()
}

func (a *Agent) Run(ctx context.Context, userMessage string) (string, error) {
	return a.RunStreaming(ctx, userMessage, nil)
}

func (a *Agent) RunStreaming(ctx context.Context, userMessage string, cb StreamCallback) (string, error) {
	history, err := a.session.Messages()
	if err != nil {
		return "", fmt.Errorf("load session: %w", err)
	}
	memory, _ := a.memory.ReadRelevant()
	messages := BuildMessages(ContextInput{
		Identity:   ReadPromptFile(a.identityPath),
		Soul:       ReadPromptFile(a.soulPath),
		SystemInfo: probeToText(a.probe),
		SkillsXML:  skills.AsPromptWithContent(a.skills),
		Memory:     memory,
		Session:    history,
		UserPrompt: userMessage,
	})
	toolDefs := BuildToolDefs(a.tools)

	selectedSkill := guessSkillName(userMessage, a.skills)
	ev, _ := evidence.Start(a.runRoot, selectedSkill, a.target)
	if ev != nil {
		defer ev.Finalize("", nil)
	}

	var finalText strings.Builder
	forcedToolRetry := false
	for iterations := 0; iterations < 20; iterations++ {
		resp, err := a.provider.Chat(ctx, messages, toolDefs)
		if err != nil {
			return "", err
		}
		if len(resp.ToolCalls) == 0 {
			if !forcedToolRetry && isSystemQuestion(userMessage) {
				forcedToolRetry = true
				messages = append(messages, llm.Message{
					Role:    llm.RoleUser,
					Content: "You MUST use available tools to answer this system question. Execute commands/read files to gather live data before concluding.",
				})
				continue
			}
			finalMsg := a.withTargetPrefix(resp.FinalMessage)
			if cb != nil {
				cb(StreamEvent{Type: EventTextDelta, Text: finalMsg})
				cb(StreamEvent{Type: EventDone})
			}
			finalText.WriteString(finalMsg)
			_ = a.session.Append(llm.Message{Role: llm.RoleUser, Content: userMessage})
			_ = a.session.Append(llm.Message{Role: llm.RoleAssist, Content: finalMsg})
			if ev != nil {
				_ = ev.Finalize(finalMsg, map[string]any{"target": a.target, "skill": selectedSkill})
			}
			if a.notify != "" && a.reporter != nil {
				_ = a.reporter.Send(ctx, channels.Message{
					Channel:  a.notify,
					Title:    "Kai Report",
					Body:     finalMsg,
					Severity: "info",
				})
			}
			return finalText.String(), nil
		}

		toolResults := make([]tools.Result, 0, len(resp.ToolCalls))
		for _, tc := range resp.ToolCalls {
			if cb != nil {
				cb(StreamEvent{Type: EventToolCall, Summary: toolSummary(tc)})
			}
			if a.policy != nil {
				decision := a.policy.Check(tc.Name, tc.Args)
				if decision.Decision == policy.Block {
					toolResults = append(toolResults, ToolBlockedMessage(tc.Name, decision.Reason))
					continue
				}
				if decision.Decision == policy.Confirm {
					toolResults = append(toolResults, ToolBlockedMessage(tc.Name, "requires confirmation: "+decision.Reason))
					continue
				}
			}
			res, err := a.tools.Execute(ctx, []llm.ToolCall{tc}, tools.Dependencies{Executor: a.exec, Evidence: ev, Reporter: a.reporter, Target: a.target, Policy: a.policy})
			if err != nil {
				toolResults = append(toolResults, tools.Result{Tool: tc.Name, Success: false, Error: err.Error()})
				continue
			}
			if len(res) == 0 {
				toolResults = append(toolResults, tools.Result{Tool: tc.Name, Success: false, Error: "no tool result"})
				continue
			}
			toolResults = append(toolResults, res[0])
			a.afterToolCall(tc)
			if cb != nil {
				exitCode := extractExitCode(res[0].Output)
				cb(StreamEvent{Type: EventToolResult, ExitCode: exitCode})
			}
		}
		messages = append(messages, llm.Message{Role: llm.RoleTool, Content: FormatToolResults(toolResults)})
	}
	return "", fmt.Errorf("max tool-call iterations reached")
}

func (a *Agent) afterToolCall(tc llm.ToolCall) {
	if tc.Name != "write" {
		return
	}
	var args map[string]any
	if err := json.Unmarshal(tc.Args, &args); err != nil {
		return
	}
	path, _ := args["path"].(string)
	path = strings.TrimSpace(path)
	if path == "" {
		return
	}
	path = strings.ReplaceAll(path, "~/.kai", config.DefaultRoot())
	if !strings.Contains(path, filepath.Clean(config.DefaultCommunitySkillRoot())) {
		return
	}
	if !strings.HasSuffix(path, "SKILL.md") && !strings.HasSuffix(path, "metadata.yaml") {
		return
	}
	updated, err := loadEnabledSkills(a.probe, a.skillEnabled, a.skillDisabled, a.skillDirs)
	if err == nil {
		a.skills = updated
	}
}

func loadEnabledSkills(probe *executor.ProbeResult, enabled, disabled, extraDirs []string) ([]skills.Skill, error) {
	sk, err := skills.LoadAllSkills(probe, disabled, extraDirs)
	if err != nil {
		return nil, err
	}
	if len(enabled) == 0 {
		return sk, nil
	}
	enabledSet := make(map[string]struct{}, len(enabled))
	for _, name := range enabled {
		enabledSet[strings.TrimSpace(name)] = struct{}{}
	}
	filtered := make([]skills.Skill, 0, len(sk))
	for _, item := range sk {
		if _, ok := enabledSet[item.Name]; ok {
			filtered = append(filtered, item)
		}
	}
	return filtered, nil
}

func probeToText(p *executor.ProbeResult) string {
	if p == nil {
		return ""
	}
	return p.String()
}

func guessSkillName(prompt string, sk []skills.Skill) string {
	p := strings.ToLower(prompt)
	for _, s := range sk {
		if strings.Contains(p, strings.ToLower(s.Name)) {
			return s.Name
		}
	}
	if strings.Contains(p, "slow") || strings.Contains(p, "performance") {
		for _, s := range sk {
			if strings.Contains(strings.ToLower(s.Name), "perf") {
				return s.Name
			}
		}
	}
	if len(sk) > 0 {
		return sk[0].Name
	}
	return "general"
}

func toolSummary(tc llm.ToolCall) string {
	summary := tc.Name
	var parsed map[string]any
	if err := json.Unmarshal(tc.Args, &parsed); err == nil {
		if command, ok := parsed["command"].(string); ok {
			summary = fmt.Sprintf("%s: %s", tc.Name, truncate(command, 80))
		}
	}
	return summary
}

func extractExitCode(output string) *int {
	var obj map[string]any
	if err := json.Unmarshal([]byte(output), &obj); err != nil {
		return nil
	}
	if v, ok := obj["exit_code"].(float64); ok {
		i := int(v)
		return &i
	}
	return nil
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}

func (a *Agent) withTargetPrefix(msg string) string {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return msg
	}
	if a.probe == nil {
		return fmt.Sprintf("[%s]\n\n%s", a.target, msg)
	}
	osName := strings.TrimSpace(a.probe.Distro)
	if osName == "" {
		osName = strings.TrimSpace(a.probe.OS)
	}
	header := fmt.Sprintf("[%s · %s · %s]", a.target, osName, strings.TrimSpace(a.probe.Kernel))
	return header + "\n\n" + msg
}

func isSystemQuestion(input string) bool {
	p := strings.ToLower(strings.TrimSpace(input))
	if p == "" {
		return false
	}
	keywords := []string{
		"kernel", "memory", "disk", "distro", "os", "uptime", "load", "cpu",
		"network", "port", "process", "service", "audit", "updates", "cve",
		"latency", "slow", "health", "server",
	}
	for _, k := range keywords {
		if strings.Contains(p, k) {
			return true
		}
	}
	return strings.HasPrefix(p, "run ") || strings.HasPrefix(p, "execute ")
}

type Loop struct {
	Provider     llm.Provider
	Tools        *tools.Registry
	Session      *Session
	Memory       *MemoryStore
	Executor     executor.Executor
	Policy       *policy.Policy
	IdentityPath string
	SoulPath     string
}

func (l *Loop) RunOnce(ctx context.Context, userPrompt string) (string, error) {
	a := &Agent{provider: l.Provider, tools: l.Tools, session: l.Session, memory: l.Memory, exec: l.Executor, policy: l.Policy, reporter: &channels.MultiDispatcher{Default: &channels.CLIChannel{}}, identityPath: l.IdentityPath, soulPath: l.SoulPath, target: "local"}
	return a.Run(ctx, userPrompt)
}
