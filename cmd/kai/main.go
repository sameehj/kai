package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/sameehj/kai/pkg/adapter"
	"github.com/sameehj/kai/pkg/agent"
	"github.com/sameehj/kai/pkg/agent/llm"
	"github.com/sameehj/kai/pkg/env"
	"github.com/sameehj/kai/pkg/gateway"
	"github.com/sameehj/kai/pkg/session"
	"github.com/sameehj/kai/pkg/workspace"
	"github.com/spf13/cobra"
)

const (
	defaultGatewayListenAddr = "127.0.0.1:18790"
	defaultGatewayWSAddr     = "ws://127.0.0.1:18790/ws"
)

var gatewayListenAddrFlag string
var chatResetFlag bool

func main() {
	_ = env.LoadFromDir(workspace.Resolve())

	rootCmd := &cobra.Command{
		Use:   "kai",
		Short: "KAI - Local AI Assistant",
	}

	gatewayCmd := &cobra.Command{
		Use:   "gateway",
		Short: "Start the gateway daemon",
		RunE:  runGateway,
	}
	gatewayCmd.Flags().StringVar(&gatewayListenAddrFlag, "listen", gatewayListenAddr(), "Gateway listen address (host:port)")

	chatCmd := &cobra.Command{
		Use:          "chat",
		Short:        "Interactive chat with KAI",
		SilenceUsage: true,
		RunE:         runChat,
	}
	chatCmd.Flags().BoolVar(&chatResetFlag, "reset", false, "Reset chat session history before starting")

	mcpCmd := &cobra.Command{
		Use:   "mcp",
		Short: "Start MCP channel adapter (stdio)",
		RunE:  runMCP,
	}

	initCmd := &cobra.Command{
		Use:   "init",
		Short: "Initialize workspace",
		RunE:  runInit,
	}

	loginCmd := &cobra.Command{
		Use:   "login",
		Short: "Authenticate account login for OpenAI via Codex",
		RunE:  runLogin,
	}

	rootCmd.AddCommand(gatewayCmd, chatCmd, mcpCmd, initCmd, loginCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func runGateway(cmd *cobra.Command, args []string) error {
	client := selectLLMClient()
	runtime := agent.NewRuntime(&agent.Config{Workspace: workspace.Resolve(), LLM: client})
	listenAddr := strings.TrimSpace(gatewayListenAddrFlag)
	if listenAddr == "" {
		listenAddr = gatewayListenAddr()
	}
	server := gateway.NewServer(listenAddr, runtime)
	fmt.Printf("KAI Gateway starting on %s\n", listenAddr)
	return server.Start(context.Background())
}

func runChat(cmd *cobra.Command, args []string) error {
	if chatResetFlag {
		path := filepath.Join(workspace.HomeDir(), "sessions", string(session.MainSession)+".json")
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	cli := adapter.NewCLIAdapter(gatewayWSAddr())
	return cli.Start(context.Background())
}

func runMCP(cmd *cobra.Command, args []string) error {
	mcp := adapter.NewMCPAdapter(gatewayWSAddr())
	return mcp.Start(context.Background())
}

func runInit(cmd *cobra.Command, args []string) error {
	ws := workspace.Resolve()
	agentsPath := filepath.Join(ws, workspace.AgentsFile)
	if _, err := os.Stat(agentsPath); os.IsNotExist(err) {
		if err := os.WriteFile(agentsPath, []byte(workspace.DefaultAgentsMD), 0o644); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Join(ws, workspace.SkillsDir), 0o755); err != nil {
		return err
	}

	home := workspace.HomeDir()
	_ = os.MkdirAll(filepath.Join(home, "sessions"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, "memory"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, "logs"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, "artifacts"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, "skills"), 0o755)

	fmt.Println("KAI workspace initialized")
	return nil
}

func runLogin(cmd *cobra.Command, args []string) error {
	c := exec.Command("codex", "login")
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	c.Stdin = os.Stdin
	if err := c.Run(); err != nil {
		return err
	}
	if llm.OpenAIAccountLoginAvailable() {
		fmt.Println("Account login available for KAI OpenAI provider")
	} else {
		fmt.Println("Login completed, but no reusable account token was detected")
	}
	return nil
}

func selectLLMClient() agent.LLMClient {
	provider := strings.ToLower(strings.TrimSpace(os.Getenv("KAI_PROVIDER")))
	switch provider {
	case "openai":
		return llm.NewOpenAIClient(os.Getenv("OPENAI_API_KEY"), os.Getenv("OPENAI_MODEL"))
	case "anthropic":
		if os.Getenv("ANTHROPIC_API_KEY") != "" {
			return llm.NewAnthropicClient(os.Getenv("ANTHROPIC_API_KEY"), os.Getenv("ANTHROPIC_MODEL"))
		}
	default:
		if os.Getenv("OPENAI_API_KEY") != "" || llm.OpenAIAccountLoginAvailable() {
			return llm.NewOpenAIClient(os.Getenv("OPENAI_API_KEY"), os.Getenv("OPENAI_MODEL"))
		}
		if os.Getenv("ANTHROPIC_API_KEY") != "" {
			return llm.NewAnthropicClient(os.Getenv("ANTHROPIC_API_KEY"), os.Getenv("ANTHROPIC_MODEL"))
		}
	}
	return nil
}

func gatewayWSAddr() string {
	if v := strings.TrimSpace(os.Getenv("KAI_GATEWAY_ADDR")); v != "" {
		return v
	}
	if listen := strings.TrimSpace(os.Getenv("KAI_GATEWAY_LISTEN")); listen != "" {
		u := url.URL{Scheme: "ws", Host: listen, Path: "/ws"}
		return u.String()
	}
	return defaultGatewayWSAddr
}

func gatewayListenAddr() string {
	if v := strings.TrimSpace(os.Getenv("KAI_GATEWAY_LISTEN")); v != "" {
		return v
	}
	return defaultGatewayListenAddr
}
