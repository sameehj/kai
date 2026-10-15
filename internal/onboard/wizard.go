package onboard

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/smtp"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kai-agent/kai/internal/agent"
	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/executor"
)

func RunFirstTime() error { return RunInteractive() }

func RunInteractive() error {
	r := bufio.NewScanner(os.Stdin)
	r.Buffer(make([]byte, 1024), 1024*1024)
	cfg := config.DefaultConfig()

	stepWelcome()
	if err := mustHome(); err != nil {
		return err
	}

	if err := stepLLM(r, cfg); err != nil {
		return err
	}
	targetName, probe, err := stepTarget(r, cfg)
	if err != nil {
		return err
	}
	if err := saveProbe(targetName, probe); err != nil {
		return err
	}
	stepSkills(r, cfg)
	_ = stepNotifications(r, cfg, targetName)
	stepSafety(r, cfg)

	if err := os.MkdirAll(config.DefaultWorkspaceRoot(), 0o755); err != nil {
		return err
	}
	_ = os.WriteFile(config.DefaultIdentityPath(), []byte(defaultIdentity), 0o644)
	_ = os.WriteFile(config.DefaultSoulPath(), []byte(defaultSoul), 0o644)

	if err := config.Save(config.DefaultConfigPath(), cfg); err != nil {
		return err
	}

	fmt.Println("\n🚀 Running first system check...")
	ag, err := agent.NewForTarget(cfg, targetName)
	if err == nil {
		defer ag.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		resp, err := ag.Run(ctx, "Give me a brief health summary of this system")
		if err == nil {
			fmt.Println(resp)
		} else {
			if strings.EqualFold(cfg.LLM.Provider, "ollama") && looksLikeOllamaConnError(err) {
				fmt.Println("⚠️  First health check skipped - Ollama not reachable.")
				fmt.Println("    Start Ollama with: ollama serve")
				fmt.Println("    Then try: kai \"check system health\"")
			} else {
				fmt.Printf("Health check failed: %v\n", err)
			}
		}
	}

	fmt.Println("\n🎉 Kai is ready!")
	fmt.Printf("\nControlling: %s\n", targetName)
	fmt.Println("\nTry:")
	fmt.Println("  kai \"why is my server slow?\"")
	fmt.Println("  kai \"check network health\"")
	fmt.Println("  kai \"what kernel am I running?\"")
	return nil
}

func stepWelcome() {
	fmt.Println()
	fmt.Println("🤖 Kai — Linux Systems Agent")
	fmt.Println()
	fmt.Println("I run on your machine and operate Linux systems safely.")
	fmt.Println("Setup takes ~2 minutes.")
}

func stepLLM(r *bufio.Scanner, cfg *config.Config) error {
	for {
		fmt.Println("\n🧠 Choose AI provider:")
		fmt.Println("  1) Claude (Anthropic) — recommended")
		fmt.Println("  2) OpenAI")
		fmt.Println("  3) Ollama (local, no API key)")
		choice := ask(r, "Choice [1]: ", "1")
		switch choice {
		case "1":
			cfg.LLM.Provider = "anthropic"
			cfg.LLM.Model = "claude-3-5-sonnet-latest"
			for {
				key := ask(r, "🔑 Paste API key: ", "")
				start := time.Now()
				if err := verifyAnthropic(key, cfg.LLM.Model); err == nil {
					cfg.LLM.APIKey = key
					fmt.Printf("✅ Connected to Claude Sonnet (%dms)\n", time.Since(start).Milliseconds())
					return nil
				} else {
					fmt.Printf("❌ Connection failed: %v\n", err)
					if strings.ToLower(ask(r, "Try again? (y/n) [y]: ", "y")) != "y" {
						return fmt.Errorf("provider verification failed")
					}
				}
			}
		case "2":
			cfg.LLM.Provider = "openai"
			cfg.LLM.Model = "gpt-4o-mini"
			for {
				key := ask(r, "🔑 Paste API key: ", "")
				start := time.Now()
				if err := verifyOpenAI(key, cfg.LLM.Model); err == nil {
					cfg.LLM.APIKey = key
					fmt.Printf("✅ Connected to OpenAI (%dms)\n", time.Since(start).Milliseconds())
					return nil
				} else {
					fmt.Printf("❌ Connection failed: %v\n", err)
					if strings.ToLower(ask(r, "Try again? (y/n) [y]: ", "y")) != "y" {
						return fmt.Errorf("provider verification failed")
					}
				}
			}
		default:
			cfg.LLM.Provider = "ollama"
			model := ask(r, "Model name [llama3]: ", "llama3")
			cfg.LLM.Model = model
			models, err := detectOllama()
			if err != nil {
				fmt.Println("⚠️  Cannot connect to Ollama at localhost:11434")
				fmt.Println("   Start it with: ollama serve")
				fmt.Println("   Or choose a different provider.")
				continue
			}
			if len(models) == 0 {
				fmt.Println("⚠️  Ollama is running but has no models installed.")
				fmt.Println("   Install one with: ollama pull llama3")
				continue
			}
			fmt.Println("✅ Ollama detected. Models:")
			for _, m := range models {
				fmt.Printf("   • %s\n", m)
			}
			return nil
		}
	}
}

func stepTarget(r *bufio.Scanner, cfg *config.Config) (string, *executor.ProbeResult, error) {
	fmt.Println("\n🖥  Where does Kai operate?")
	fmt.Println("  1) This machine (localhost)")
	fmt.Println("  2) SSH to a remote server")
	fmt.Println("  3) Docker container")
	fmt.Println("  4) Demo mode (built-in test environment)")
	choice := ask(r, "Choice [1]: ", "1")

	name := "local"
	target := config.Target{Type: "local", Default: true}

	switch choice {
	case "2":
		name = ask(r, "Target name [dev-vm]: ", "dev-vm")
		target.Type = "ssh"
		target.Host = ask(r, "Host: ", "")
		target.Port = atoiDefault(ask(r, "Port [22]: ", "22"), 22)
		target.User = ask(r, "User: ", "")
		target.Key = ask(r, "SSH key [~/.ssh/id_ed25519]: ", "~/.ssh/id_ed25519")
	case "3":
		name = ask(r, "Target name [container]: ", "container")
		target.Type = "docker"
		target.Container = ask(r, "Container name or ID: ", "")
	case "4":
		name = "demo"
		target.Type = "docker"
		target.Container = "slow-app-app-1"
		if err := ensureDemoRunning(r); err != nil {
			return "", nil, err
		}
	}
	cfg.Targets = map[string]config.Target{name: target}

	fmt.Println("\n🔎 Probing system...")
	for {
		ex, err := executor.BuildExecutor(executor.TargetSpec{Type: target.Type, Host: target.Host, Port: target.Port, User: target.User, KeyFile: expandHome(target.Key), Container: target.Container})
		if err != nil {
			if strings.ToLower(ask(r, "Connection failed. Retry? (y/n) [y]: ", "y")) == "y" {
				continue
			}
			return "", nil, err
		}
		probe, err := executor.Probe(context.Background(), ex)
		if err != nil {
			if strings.ToLower(ask(r, "Probe failed. Retry? (y/n) [y]: ", "y")) == "y" {
				continue
			}
			return "", nil, err
		}
		probe.Name = name
		printProbeSummary(probe)
		return name, probe, nil
	}
}

func stepSkills(r *bufio.Scanner, cfg *config.Config) {
	fmt.Println("\n🧩 What should Kai help with?")
	envSetup := yesno(r, "Enable Environment setup? [Y/n]: ", true)
	buildDebug := yesno(r, "Enable Build debugging? [Y/n]: ", true)
	watch := yesno(r, "Enable Watch/monitoring? [Y/n]: ", true)
	serverAudit := yesno(r, "Enable Server audit? [Y/n]: ", true)
	perf := yesno(r, "Enable Performance diagnosis? [Y/n]: ", true)
	ebpfDev := yesno(r, "Enable eBPF development? [Y/n]: ", true)
	kernelDev := yesno(r, "Enable Kernel development? [Y/n]: ", true)
	net := yesno(r, "Enable Network debugging? [Y/n]: ", true)
	kernelWatch := yesno(r, "Enable Kernel monitoring? [Y/n]: ", true)
	enabled := []string{}
	if envSetup {
		enabled = append(enabled, "env-setup")
	}
	if buildDebug {
		enabled = append(enabled, "build-debug")
	}
	if watch {
		enabled = append(enabled, "watch")
	}
	if serverAudit {
		enabled = append(enabled, "server-audit")
	}
	if perf {
		enabled = append(enabled, "perf-diagnosis")
	}
	if ebpfDev {
		enabled = append(enabled, "ebpf-dev")
	}
	if kernelDev {
		enabled = append(enabled, "kernel-dev")
	}
	if net {
		enabled = append(enabled, "net-debug")
	}
	if kernelWatch {
		enabled = append(enabled, "kernel-watch")
	}
	cfg.Skills.Enabled = enabled
}

func stepNotifications(r *bufio.Scanner, cfg *config.Config, targetName string) error {
	fmt.Println("\n💬 Where should Kai send reports?")
	fmt.Println("  1) Terminal only (default)")
	fmt.Println("  2) Slack")
	fmt.Println("  3) Telegram")
	fmt.Println("  4) Email")
	choice := ask(r, "Choice [1]: ", "1")
	switch choice {
	case "2":
		for {
			url := ask(r, "Paste Slack Incoming Webhook URL: ", "")
			msg := channels.Message{Channel: "#ops", Title: "Kai connected", Body: "🤖 Kai connected successfully. Target: " + targetName, Severity: "info"}
			if err := (&channels.SlackChannel{WebhookURL: url}).Send(context.Background(), msg); err == nil {
				cfg.Channels.Slack.Enabled = true
				cfg.Channels.Slack.WebhookURL = url
				fmt.Println("✅ Slack connected")
				break
			}
			if strings.ToLower(ask(r, "❌ Webhook failed. Try again? (y/n) [y]: ", "y")) != "y" {
				break
			}
		}
	case "3":
		token := ask(r, "Paste Telegram Bot Token: ", "")
		uid := ask(r, "Your Telegram User ID (numeric): ", "")
		if err := sendTelegram(token, uid, "🤖 Kai connected successfully"); err == nil {
			cfg.Channels.Telegram.Enabled = true
			cfg.Channels.Telegram.BotToken = token
			cfg.Channels.Telegram.AllowedUsers = []string{uid}
			fmt.Println("✅ Telegram connected")
		} else {
			fmt.Printf("❌ Telegram failed: %v\n", err)
		}
	case "4":
		host := ask(r, "SMTP host [smtp.gmail.com]: ", "smtp.gmail.com")
		from := ask(r, "From address: ", "")
		pass := ask(r, "Password/App password: ", "")
		to := ask(r, "Test recipient email: ", from)
		if err := sendEmail(host, from, pass, to, "Kai connected", "Kai connected successfully"); err == nil {
			cfg.Channels.Email.Enabled = true
			cfg.Channels.Email.SMTPHost = host
			cfg.Channels.Email.SMTPPort = 587
			cfg.Channels.Email.From = from
			cfg.Channels.Email.Password = pass
			fmt.Println("✅ Email connected")
		} else {
			fmt.Printf("❌ Email failed: %v\n", err)
		}
	}
	return nil
}

func stepSafety(r *bufio.Scanner, cfg *config.Config) {
	fmt.Println("\n🛡️  Safety level:")
	fmt.Println("  1) Confirm before changes (recommended)")
	fmt.Println("  2) Read-only mode (safest)")
	fmt.Println("  3) Auto-execute (advanced)")
	choice := ask(r, "Choice [1]: ", "1")
	switch choice {
	case "2":
		cfg.Policy.DefaultMode = "readonly"
	case "3":
		cfg.Policy.DefaultMode = "allow"
	default:
		cfg.Policy.DefaultMode = "confirm"
	}
}

func saveProbe(name string, probe *executor.ProbeResult) error {
	if probe == nil {
		return nil
	}
	root := config.DefaultTargetsProbeRoot()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(probe, "", "  ")
	return os.WriteFile(filepath.Join(root, name+".json"), b, 0o644)
}

func ensureDemoRunning(r *bufio.Scanner) error {
	out, _ := exec.Command("sh", "-lc", "docker ps --format '{{.Names}}' | grep -E 'slow-app' || true").Output()
	if strings.TrimSpace(string(out)) != "" {
		return nil
	}
	if !yesno(r, "Demo is not running. Start it now? [Y/n]: ", true) {
		return fmt.Errorf("demo not running")
	}
	cmd := exec.Command("sh", "-lc", "make demo-setup")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func verifyAnthropic(key, model string) error {
	if strings.TrimSpace(key) == "" {
		return fmt.Errorf("empty key")
	}
	if model == "" {
		model = "claude-3-5-sonnet-latest"
	}
	payload := map[string]any{"model": model, "max_tokens": 1, "messages": []map[string]string{{"role": "user", "content": "hi"}}}
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPost, "https://api.anthropic.com/v1/messages", bytes.NewReader(b))
	req.Header.Set("x-api-key", key)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("content-type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("status %s", resp.Status)
	}
	return nil
}

func verifyOpenAI(key, model string) error {
	if strings.TrimSpace(key) == "" {
		return fmt.Errorf("empty key")
	}
	if model == "" {
		model = "gpt-4o-mini"
	}
	payload := map[string]any{"model": model, "max_tokens": 1, "messages": []map[string]string{{"role": "user", "content": "hi"}}}
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPost, "https://api.openai.com/v1/chat/completions", bytes.NewReader(b))
	req.Header.Set("authorization", "Bearer "+key)
	req.Header.Set("content-type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("status %s", resp.Status)
	}
	return nil
}

func detectOllama() ([]string, error) {
	req, _ := http.NewRequest(http.MethodGet, "http://localhost:11434/api/tags", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("status %s", resp.Status)
	}
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tags); err != nil {
		return nil, err
	}
	models := make([]string, 0, len(tags.Models))
	for _, m := range tags.Models {
		if strings.TrimSpace(m.Name) != "" {
			models = append(models, strings.TrimSpace(m.Name))
		}
	}
	return models, nil
}

func sendTelegram(token, userID, text string) error {
	if token == "" || userID == "" {
		return fmt.Errorf("missing token or user id")
	}
	u := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	payload := map[string]any{"chat_id": userID, "text": text}
	b, _ := json.Marshal(payload)
	resp, err := http.Post(u, "application/json", bytes.NewReader(b))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("status %s", resp.Status)
	}
	return nil
}

func sendEmail(host, from, pass, to, subject, body string) error {
	if host == "" || from == "" || pass == "" || to == "" {
		return fmt.Errorf("missing smtp fields")
	}
	msg := []byte("To: " + to + "\r\nSubject: " + subject + "\r\n\r\n" + body + "\r\n")
	auth := smtp.PlainAuth("", from, pass, host)
	return smtp.SendMail(host+":587", auth, from, []string{to}, msg)
}

func printProbeSummary(p *executor.ProbeResult) {
	fmt.Printf("✅ %s\n", nonempty(p.Distro, p.OS))
	fmt.Printf("✅ Kernel %s (%s)\n", p.Kernel, p.Arch)
	if p.CPUCores > 0 {
		fmt.Printf("✅ CPU: %d cores\n", p.CPUCores)
	}
	if p.MemoryTotal != "" {
		fmt.Printf("✅ Memory: %s\n", p.MemoryTotal)
	}
	fmt.Printf("✅ eBPF: %s\n", p.EBPFStatus)
	present := []string{}
	for _, b := range []string{"ss", "perf", "iostat", "mpstat", "vmstat"} {
		if p.Binaries[b] {
			present = append(present, b)
		}
	}
	if len(present) > 0 {
		fmt.Printf("✅ Tools: %s\n", strings.Join(present, ", "))
	}
	if len(p.Missing) > 0 {
		fmt.Printf("⚠️  Missing: %s\n", strings.Join(p.Missing, ", "))
	}
}

func ask(r *bufio.Scanner, prompt, def string) string {
	fmt.Print(prompt)
	if !r.Scan() {
		return def
	}
	v := strings.TrimSpace(r.Text())
	if v == "" {
		return def
	}
	return v
}

func yesno(r *bufio.Scanner, prompt string, def bool) bool {
	d := "n"
	if def {
		d = "y"
	}
	v := strings.ToLower(ask(r, prompt, d))
	return v == "y" || v == "yes"
}

func nonempty(v ...string) string {
	for _, s := range v {
		if strings.TrimSpace(s) != "" {
			return s
		}
	}
	return "unknown"
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, strings.TrimPrefix(p, "~/"))
	}
	return p
}

func atoiDefault(s string, d int) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return d
	}
	var n int
	_, err := fmt.Sscanf(s, "%d", &n)
	if err != nil || n <= 0 {
		return d
	}
	return n
}

func mustHome() error {
	if err := os.MkdirAll(config.DefaultRoot(), 0o700); err != nil {
		fmt.Printf("❌ Cannot create %s directory: %v\n", config.DefaultRoot(), err)
		fmt.Printf("   Try: mkdir -p %s && chmod 700 %s\n", config.DefaultRoot(), config.DefaultRoot())
		return err
	}
	return nil
}

func looksLikeOllamaConnError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "localhost:11434") && strings.Contains(msg, "connect")
}

const defaultIdentity = `# Kai

I am Kai, a Linux systems agent.

I run on the developer's machine and operate Linux systems remotely via SSH.
I diagnose performance issues, monitor kernel updates, track security
vulnerabilities, and automate infrastructure tasks.

I am methodical. I gather evidence before drawing conclusions.
I show my work. Every command I run is logged.
I explain my reasoning in plain language.
I am honest about what I don't know.

I am not a chatbot. I am not a code editor. I am a systems engineer
that happens to be an AI.
`

const defaultSoul = `# How I work

1. I ALWAYS probe the target first to understand what I'm working with.
2. I follow skill playbooks systematically — I don't skip steps.
3. I NEVER guess at root causes — I gather evidence.
4. I present findings as: summary → evidence → timeline → recommendations.
5. I log every action to the evidence directory.
6. I ask for confirmation before making changes (unless policy pre-approves).
7. I degrade gracefully — if bpftrace isn't available, I use /proc.
8. I am concise in reports but thorough in investigation.
`
