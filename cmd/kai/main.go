package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/kai-agent/kai/internal/agent"
	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/evidence"
	"github.com/kai-agent/kai/internal/gateway"
	"github.com/kai-agent/kai/internal/onboard"
)

func main() {
	config.LoadDotEnv()
	if !config.Exists(config.DefaultConfigPath()) && !isHelpOrVersion(os.Args) && isInteractiveTerminal() {
		must(onboard.RunFirstTime())
	}
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "init":
			must(onboard.RunInteractive())
			return
		case "probe":
			runProbe(os.Args[2:])
			return
		case "gateway":
			runGateway(os.Args[2:])
			return
		case "replay":
			runReplay(os.Args[2:])
			return
		case "runs":
			runRuns(os.Args[2:])
			return
		case "skill":
			runSkill(os.Args[1:])
			return
		}
	}
	runChat(os.Args[1:])
}

func runChat(args []string) {
	fs := flag.NewFlagSet("kai", flag.ExitOnError)
	singleShot := fs.String("c", "", "single-shot query")
	target := fs.String("target", "", "target name from config")
	notify := fs.String("notify", "", "Channel to send final report, e.g. slack:#ops")
	_ = fs.Parse(args)

	cfg := loadConfigOrDefault()
	applyLLMCredentials(cfg)
	if strings.TrimSpace(cfg.LLM.APIKey) == "" && strings.ToLower(cfg.LLM.Provider) != "ollama" {
		fmt.Fprintln(os.Stderr, "No LLM API key found. Set one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, CODEX_API_KEY")
		os.Exit(1)
	}

	ag, err := agent.NewForTarget(cfg, *target)
	must(err)
	defer ag.Close()
	ag.SetNotifyChannel(strings.TrimSpace(*notify))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		cancel()
		fmt.Println("\nBye.")
		os.Exit(0)
	}()

	if strings.TrimSpace(*singleShot) != "" {
		resp, err := ag.Run(ctx, *singleShot)
		must(err)
		fmt.Println(resp)
		return
	}

	fmt.Println("kai")
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	for {
		fmt.Print("kai> ")
		if !scanner.Scan() {
			break
		}
		input := strings.TrimSpace(scanner.Text())
		if input == "" {
			continue
		}
		if input == "exit" || input == "quit" {
			break
		}
		_, err := ag.RunStreaming(ctx, input, func(event agent.StreamEvent) {
			switch event.Type {
			case agent.EventToolCall:
				fmt.Printf("  -> %s\n", event.Summary)
			case agent.EventToolResult:
				if event.ExitCode != nil && *event.ExitCode != 0 {
					fmt.Printf("  <- error (exit %d)\n", *event.ExitCode)
				}
			case agent.EventTextDelta:
				fmt.Print(event.Text)
			case agent.EventDone:
				fmt.Println()
			}
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		fmt.Println()
	}
}

func runProbe(args []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	target := fs.String("target", "", "target name")
	_ = fs.Parse(args)
	cfg := loadConfigOrDefault()
	if *target == "" {
		*target = config.DefaultTargetName(cfg.Targets)
	}
	probe, err := onboard.ProbeTarget(context.Background(), cfg, *target)
	must(err)
	fmt.Println(probe.String())
}

func runGateway(args []string) {
	action := "start"
	if len(args) > 0 {
		action = args[0]
	}
	cfg := loadConfigOrDefault()
	gw := gateway.New(cfg)
	switch action {
	case "start":
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		sigs := make(chan os.Signal, 1)
		signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
		go func() { <-sigs; cancel() }()
		fmt.Printf("Gateway listening on %s\n", cfg.Gateway.Addr)
		must(gw.Start(ctx))
	case "stop":
		pidBytes, err := os.ReadFile(config.DefaultGatewayPIDPath())
		must(err)
		pid, err := strconv.Atoi(strings.TrimSpace(string(pidBytes)))
		must(err)
		proc, err := os.FindProcess(pid)
		must(err)
		must(proc.Signal(syscall.SIGTERM))
		fmt.Printf("Sent SIGTERM to gateway pid %d\n", pid)
	case "status":
		running, details := gw.Status()
		if running {
			fmt.Printf("running (pid %s)", strings.TrimSpace(details))
			fmt.Println()
			return
		}
		fmt.Println("stopped")
	default:
		fmt.Println("usage: kai gateway start|stop|status")
	}
}

func runReplay(args []string) {
	runID := "last"
	if len(args) > 0 {
		runID = args[0]
	}
	cfg := loadConfigOrDefault()
	out, err := evidence.Replay(cfg.Evidence.Dir, runID)
	must(err)
	fmt.Print(out)
}

func runRuns(args []string) {
	cfg := loadConfigOrDefault()
	action := "list"
	if len(args) > 0 {
		action = args[0]
	}
	switch action {
	case "list":
		runs, err := evidence.ListRuns(cfg.Evidence.Dir)
		must(err)
		for _, r := range runs {
			fmt.Println(r)
		}
	case "diff":
		if len(args) < 3 {
			fmt.Println("usage: kai runs diff <run-a> <run-b>")
			return
		}
		out, err := evidence.DiffSummary(cfg.Evidence.Dir, args[1], args[2])
		must(err)
		fmt.Println(out)
	default:
		fmt.Println("usage: kai runs list|diff")
	}
}

func loadConfigOrDefault() *config.Config {
	cfg, err := config.Load()
	if err != nil {
		return config.DefaultConfig()
	}
	cfg.ResolveEnvVars()
	cfg.ApplyCompat()
	return cfg
}

func detectAPIKey() (string, string) {
	checks := []struct {
		env      string
		provider string
	}{
		{"ANTHROPIC_API_KEY", "anthropic"},
		{"OPENAI_API_KEY", "openai"},
		{"CODEX_API_KEY", "codex"},
	}
	for _, c := range checks {
		if val := strings.TrimSpace(os.Getenv(c.env)); val != "" {
			return c.provider, val
		}
	}
	return "", ""
}

func applyLLMCredentials(cfg *config.Config) {
	if cfg == nil {
		return
	}
	provider := strings.ToLower(strings.TrimSpace(cfg.LLM.Provider))
	if provider == "" {
		if p, key := detectAPIKey(); key != "" {
			cfg.LLM.Provider = p
			cfg.LLM.APIKey = key
		}
		return
	}
	if provider == "ollama" {
		return
	}
	if strings.TrimSpace(cfg.LLM.APIKey) != "" {
		return
	}
	switch provider {
	case "anthropic":
		cfg.LLM.APIKey = strings.TrimSpace(os.Getenv("ANTHROPIC_API_KEY"))
	case "openai":
		cfg.LLM.APIKey = strings.TrimSpace(os.Getenv("OPENAI_API_KEY"))
	case "codex":
		if v := strings.TrimSpace(os.Getenv("CODEX_API_KEY")); v != "" {
			cfg.LLM.APIKey = v
		} else {
			cfg.LLM.APIKey = strings.TrimSpace(os.Getenv("OPENAI_API_KEY"))
		}
	case "openrouter":
		cfg.LLM.APIKey = strings.TrimSpace(os.Getenv("OPENROUTER_API_KEY"))
	}
}

func must(err error) {
	if err == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "Error: %v\n", err)
	os.Exit(1)
}

func isHelpOrVersion(args []string) bool {
	for _, a := range args[1:] {
		switch a {
		case "-h", "--help", "help", "-v", "--version", "version":
			return true
		}
	}
	return false
}

func isInteractiveTerminal() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}
