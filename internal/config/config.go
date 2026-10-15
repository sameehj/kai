package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	LLM       LLMConfig            `json:"llm" yaml:"llm"`
	Targets   map[string]Target    `json:"targets" yaml:"targets"`
	Channels  ChannelsConfig       `json:"channels" yaml:"channels"`
	Policy    PolicyConfig         `json:"policy" yaml:"policy"`
	Skills    SkillsConfig         `json:"skills" yaml:"skills"`
	Heartbeat HeartbeatConfig      `json:"heartbeat" yaml:"heartbeat"`
	Evidence  EvidenceConfig       `json:"evidence" yaml:"evidence"`
	Gateway   GatewayConfig        `json:"gateway" yaml:"gateway"`
	Executor  ExecutorConfigCompat `json:"executor" yaml:"executor"` // backward compatibility
}

type LLMConfig struct {
	Provider string `json:"provider" yaml:"provider"`
	Model    string `json:"model" yaml:"model"`
	APIKey   string `json:"api_key" yaml:"api_key"`
	BaseURL  string `json:"base_url,omitempty" yaml:"base_url,omitempty"`
}

type Target struct {
	Type      string   `json:"type" yaml:"type"`
	Default   bool     `json:"default,omitempty" yaml:"default,omitempty"`
	Host      string   `json:"host,omitempty" yaml:"host,omitempty"`
	Port      int      `json:"port,omitempty" yaml:"port,omitempty"`
	User      string   `json:"user,omitempty" yaml:"user,omitempty"`
	Key       string   `json:"key,omitempty" yaml:"key,omitempty"`
	Container string   `json:"container,omitempty" yaml:"container,omitempty"`
	Labels    []string `json:"labels,omitempty" yaml:"labels,omitempty"`
}

type ChannelsConfig struct {
	Slack    SlackConfig    `json:"slack" yaml:"slack"`
	Telegram TelegramConfig `json:"telegram" yaml:"telegram"`
	Email    EmailConfig    `json:"email" yaml:"email"`
}

type SlackConfig struct {
	Enabled        bool   `json:"enabled" yaml:"enabled"`
	WebhookURL     string `json:"webhook_url,omitempty" yaml:"webhook_url,omitempty"`
	DefaultChannel string `json:"default_channel,omitempty" yaml:"default_channel,omitempty"`
	BotToken       string `json:"bot_token,omitempty" yaml:"bot_token,omitempty"`
	AppToken       string `json:"app_token,omitempty" yaml:"app_token,omitempty"`
}

type TelegramConfig struct {
	Enabled      bool     `json:"enabled" yaml:"enabled"`
	BotToken     string   `json:"bot_token,omitempty" yaml:"bot_token,omitempty"`
	AllowedUsers []string `json:"allowed_users,omitempty" yaml:"allowed_users,omitempty"`
}

type EmailConfig struct {
	Enabled  bool   `json:"enabled" yaml:"enabled"`
	SMTPHost string `json:"smtp_host,omitempty" yaml:"smtp_host,omitempty"`
	SMTPPort int    `json:"smtp_port,omitempty" yaml:"smtp_port,omitempty"`
	From     string `json:"from,omitempty" yaml:"from,omitempty"`
	Password string `json:"password,omitempty" yaml:"password,omitempty"`
}

type PolicyConfig struct {
	DefaultMode string   `json:"default_mode" yaml:"default_mode"`
	AllowSudo   bool     `json:"allow_sudo" yaml:"allow_sudo"`
	Allow       []string `json:"allow" yaml:"allow"`
	Confirm     []string `json:"confirm" yaml:"confirm"`
	Block       []string `json:"block" yaml:"block"`

	// Legacy fields kept for compatibility
	Mode            string   `json:"mode,omitempty" yaml:"mode,omitempty"`
	AutoApprove     []string `json:"autoApprove,omitempty" yaml:"autoApprove,omitempty"`
	ConfirmRequired []string `json:"confirmRequired,omitempty" yaml:"confirmRequired,omitempty"`
	Blocked         []string `json:"blocked,omitempty" yaml:"blocked,omitempty"`
}

type SkillsConfig struct {
	Enabled  []string `json:"enabled" yaml:"enabled"`
	Dirs     []string `json:"dirs" yaml:"dirs"`
	Disabled []string `json:"disabled" yaml:"disabled"`
}

type HeartbeatConfig struct {
	Enabled  bool   `json:"enabled" yaml:"enabled"`
	Interval string `json:"interval" yaml:"interval"`
	Config   string `json:"config" yaml:"config"`
}

type EvidenceConfig struct {
	Dir       string `json:"dir" yaml:"dir"`
	Retention string `json:"retention" yaml:"retention"`
}

type GatewayConfig struct {
	Addr string `json:"addr" yaml:"addr"`
}

// Backward compatibility: old single executor configuration.
type ExecutorConfigCompat struct {
	Type string          `json:"type" yaml:"type"`
	SSH  SSHConfigCompat `json:"ssh" yaml:"ssh"`
}

type SSHConfigCompat struct {
	Host    string `json:"host" yaml:"host"`
	User    string `json:"user" yaml:"user"`
	KeyFile string `json:"keyFile" yaml:"keyFile"`
}

func DefaultConfig() *Config {
	return &Config{
		LLM:      LLMConfig{Provider: "anthropic", Model: "claude-3-5-sonnet-latest"},
		Executor: ExecutorConfigCompat{Type: "local"},
		Targets: map[string]Target{
			"local": {Type: "local", Default: true},
		},
		Channels: ChannelsConfig{},
		Policy: PolicyConfig{
			DefaultMode: "confirm",
			AllowSudo:   true,
			Allow: []string{
				"cat *", "ls *", "uname *", "uptime", "free *", "df *", "ss *", "ps *", "top -b *", "mpstat *", "iostat *", "vmstat *", "pidstat *", "dmesg *", "journalctl *", "head *", "tail *", "wc *", "stat *", "id", "whoami", "hostname", "ip *", "dig *", "nslookup *",
			},
			Confirm: []string{"sudo *", "bpftrace *", "systemctl *", "apt *", "dnf *", "pip *", "npm *"},
			Block:   []string{"rm -rf /", "mkfs *", "dd *of=/dev/*", "> /dev/sd*"},
		},
		Skills: SkillsConfig{Enabled: []string{
			"env-setup", "build-debug", "watch", "server-audit", "perf-diagnosis", "ebpf-dev", "kernel-dev",
			"net-debug", "kernel-watch",
		}, Dirs: []string{}, Disabled: []string{}},
		Heartbeat: HeartbeatConfig{
			Enabled:  false,
			Interval: "30m",
			Config:   filepath.Join(DefaultRoot(), "heartbeat.md"),
		},
		Evidence: EvidenceConfig{
			Dir:       filepath.Join(DefaultRoot(), "runs"),
			Retention: "30d",
		},
		Gateway: GatewayConfig{Addr: "127.0.0.1:18741"},
	}
}

func Exists(path string) bool {
	if strings.HasPrefix(path, "~") {
		path = filepath.Join(DefaultRoot(), strings.TrimPrefix(path, "~/.kai"))
	}
	_, err := os.Stat(path)
	return err == nil
}

func Load() (*Config, error) {
	if cfg, err := LoadFromPath(DefaultConfigPath()); err == nil {
		return cfg, nil
	}
	return LoadFromPath(DefaultLegacyConfigPath())
}

func LoadFromPath(path string) (*Config, error) {
	LoadDotEnv()
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			cfg := DefaultConfig()
			cfg.ResolveEnvVars()
			cfg.ApplyCompat()
			return cfg, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	cfg := DefaultConfig()
	if yaml.Unmarshal(b, cfg) != nil {
		if err := json.Unmarshal(b, cfg); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	cfg.ResolveEnvVars()
	cfg.ApplyCompat()
	return cfg, nil
}

func Save(path string, cfg *Config) error {
	if cfg == nil {
		return fmt.Errorf("nil config")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}

func (c *Config) ApplyCompat() {
	if c.Policy.DefaultMode == "" {
		if c.Policy.Mode != "" {
			c.Policy.DefaultMode = c.Policy.Mode
		} else {
			c.Policy.DefaultMode = "confirm"
		}
	}
	if len(c.Policy.Block) == 0 && len(c.Policy.Blocked) > 0 {
		c.Policy.Block = append([]string{}, c.Policy.Blocked...)
	}
	if len(c.Policy.Confirm) == 0 && len(c.Policy.ConfirmRequired) > 0 {
		c.Policy.Confirm = append([]string{}, c.Policy.ConfirmRequired...)
	}
	if len(c.Policy.Allow) == 0 && len(c.Policy.AutoApprove) > 0 {
		c.Policy.Allow = append([]string{}, c.Policy.AutoApprove...)
	}
	if len(c.Targets) == 0 {
		if strings.TrimSpace(c.Executor.Type) == "ssh" {
			c.Targets = map[string]Target{"default": {Type: "ssh", Default: true, Host: c.Executor.SSH.Host, User: c.Executor.SSH.User, Key: c.Executor.SSH.KeyFile}}
		} else {
			c.Targets = map[string]Target{"local": {Type: "local", Default: true}}
		}
	}
	if len(c.Skills.Enabled) == 0 {
		c.Skills.Enabled = []string{
			"env-setup", "build-debug", "watch", "server-audit", "perf-diagnosis", "ebpf-dev", "kernel-dev",
			"net-debug", "kernel-watch",
		}
	}
	if c.Gateway.Addr == "" {
		c.Gateway.Addr = "127.0.0.1:18741"
	}
	if c.Evidence.Dir == "" {
		c.Evidence.Dir = filepath.Join(DefaultRoot(), "runs")
	}
	if c.Heartbeat.Config == "" {
		c.Heartbeat.Config = filepath.Join(DefaultRoot(), "heartbeat.md")
	}
}

func (c *Config) ResolveEnvVars() {
	c.LLM.Provider = resolveEnv(c.LLM.Provider)
	c.LLM.Model = resolveEnv(c.LLM.Model)
	c.LLM.APIKey = resolveEnv(c.LLM.APIKey)
	c.LLM.BaseURL = resolveEnv(c.LLM.BaseURL)

	for name, t := range c.Targets {
		t.Type = resolveEnv(t.Type)
		t.Host = resolveEnv(t.Host)
		t.User = resolveEnv(t.User)
		t.Key = resolveEnv(t.Key)
		t.Container = resolveEnv(t.Container)
		c.Targets[name] = t
	}

	c.Channels.Slack.WebhookURL = resolveEnv(c.Channels.Slack.WebhookURL)
	c.Channels.Slack.DefaultChannel = resolveEnv(c.Channels.Slack.DefaultChannel)
	c.Channels.Slack.BotToken = resolveEnv(c.Channels.Slack.BotToken)
	c.Channels.Slack.AppToken = resolveEnv(c.Channels.Slack.AppToken)
	c.Channels.Telegram.BotToken = resolveEnv(c.Channels.Telegram.BotToken)
	c.Channels.Email.SMTPHost = resolveEnv(c.Channels.Email.SMTPHost)
	c.Channels.Email.From = resolveEnv(c.Channels.Email.From)
	c.Channels.Email.Password = resolveEnv(c.Channels.Email.Password)
	for i := range c.Skills.Dirs {
		c.Skills.Dirs[i] = resolveEnv(c.Skills.Dirs[i])
	}
	c.Heartbeat.Config = resolveEnv(c.Heartbeat.Config)
	c.Evidence.Dir = resolveEnv(c.Evidence.Dir)
	c.Evidence.Retention = resolveEnv(c.Evidence.Retention)
	c.Gateway.Addr = resolveEnv(c.Gateway.Addr)
	c.Executor.Type = resolveEnv(c.Executor.Type)
	c.Executor.SSH.Host = resolveEnv(c.Executor.SSH.Host)
	c.Executor.SSH.User = resolveEnv(c.Executor.SSH.User)
	c.Executor.SSH.KeyFile = resolveEnv(c.Executor.SSH.KeyFile)
}

func resolveEnv(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "${") && strings.HasSuffix(s, "}") {
		s = os.Getenv(strings.TrimSuffix(strings.TrimPrefix(s, "${"), "}"))
	} else {
		s = os.ExpandEnv(s)
	}
	if strings.HasPrefix(s, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(s, "~/"))
		}
	}
	return s
}

func WriteEnvKey(path, key, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	lines := []string{}
	if b, err := os.ReadFile(path); err == nil {
		lines = strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	}
	updated := false
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		k, _, ok := strings.Cut(trim, "=")
		if ok && strings.TrimSpace(k) == key {
			lines[i] = key + "=" + value
			updated = true
		}
	}
	if !updated {
		lines = append(lines, key+"="+value)
	}
	out := strings.Join(lines, "\n")
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return os.WriteFile(path, []byte(out), 0o600)
}

func DefaultRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".kai"
	}
	return filepath.Join(home, ".kai")
}

func DefaultEnvPath() string          { return filepath.Join(DefaultRoot(), ".env") }
func DefaultConfigPath() string       { return filepath.Join(DefaultRoot(), "config.yaml") }
func DefaultLegacyConfigPath() string { return filepath.Join(DefaultRoot(), "kai.json") }
func DefaultSessionPath() string      { return filepath.Join(DefaultRoot(), "sessions", "default.jsonl") }
func DefaultSkillRoot() string        { return filepath.Join(DefaultRoot(), "skills") }
func DefaultCommunitySkillRoot() string {
	return filepath.Join(DefaultRoot(), "community-skills")
}
func DefaultWorkspaceRoot() string    { return filepath.Join(DefaultRoot(), "workspace") }
func DefaultIdentityPath() string     { return filepath.Join(DefaultWorkspaceRoot(), "IDENTITY.md") }
func DefaultSoulPath() string         { return filepath.Join(DefaultWorkspaceRoot(), "SOUL.md") }
func DefaultMemoryFilePath() string   { return filepath.Join(DefaultWorkspaceRoot(), "MEMORY.md") }
func DefaultDailyMemoryRoot() string  { return filepath.Join(DefaultWorkspaceRoot(), "memory") }
func DefaultRunRoot() string          { return filepath.Join(DefaultRoot(), "runs") }
func DefaultGatewayPIDPath() string   { return filepath.Join(DefaultRoot(), "gateway.pid") }
func DefaultHeartbeatPath() string    { return filepath.Join(DefaultRoot(), "heartbeat.md") }
func DefaultTargetsProbeRoot() string { return filepath.Join(DefaultRoot(), "targets") }

func BundledSkillRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return "skills"
	}
	return filepath.Join(filepath.Dir(exe), "skills")
}

func DefaultTargetName(targets map[string]Target) string {
	if len(targets) == 0 {
		return ""
	}
	for name, t := range targets {
		if t.Default {
			return name
		}
	}
	names := make([]string, 0, len(targets))
	for n := range targets {
		names = append(names, n)
	}
	sort.Strings(names)
	return names[0]
}
