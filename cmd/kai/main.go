package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/sameehj/kai/pkg/adapter"
	"github.com/sameehj/kai/pkg/agent"
	"github.com/sameehj/kai/pkg/agent/llm"
	"github.com/sameehj/kai/pkg/env"
	"github.com/sameehj/kai/pkg/gateway"
	"github.com/sameehj/kai/pkg/workspace"
	"github.com/spf13/cobra"
)

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

	chatCmd := &cobra.Command{
		Use:   "chat",
		Short: "Interactive chat with KAI",
		RunE:  runChat,
	}

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

	rootCmd.AddCommand(gatewayCmd, chatCmd, mcpCmd, initCmd)
	_ = rootCmd.Execute()
}

func runGateway(cmd *cobra.Command, args []string) error {
	client := selectLLMClient()
	runtime := agent.NewRuntime(&agent.Config{Workspace: workspace.Resolve(), LLM: client})
	server := gateway.NewServer(":18789", runtime)
	fmt.Println("KAI Gateway starting on 127.0.0.1:18789")
	return server.Start(context.Background())
}

func runChat(cmd *cobra.Command, args []string) error {
	cli := adapter.NewCLIAdapter("ws://127.0.0.1:18789/ws")
	return cli.Start(context.Background())
}

func runMCP(cmd *cobra.Command, args []string) error {
	mcp := adapter.NewMCPAdapter("ws://127.0.0.1:18789/ws")
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

	fmt.Println("KAI workspace initialized")
	return nil
}

func selectLLMClient() agent.LLMClient {
	provider := strings.ToLower(strings.TrimSpace(os.Getenv("KAI_PROVIDER")))
	switch provider {
	case "openai":
		if os.Getenv("OPENAI_API_KEY") != "" {
			return llm.NewOpenAIClient(os.Getenv("OPENAI_API_KEY"), os.Getenv("OPENAI_MODEL"))
		}
	case "anthropic":
		if os.Getenv("ANTHROPIC_API_KEY") != "" {
			return llm.NewAnthropicClient(os.Getenv("ANTHROPIC_API_KEY"), os.Getenv("ANTHROPIC_MODEL"))
		}
	default:
		if os.Getenv("OPENAI_API_KEY") != "" {
			return llm.NewOpenAIClient(os.Getenv("OPENAI_API_KEY"), os.Getenv("OPENAI_MODEL"))
		}
		if os.Getenv("ANTHROPIC_API_KEY") != "" {
			return llm.NewAnthropicClient(os.Getenv("ANTHROPIC_API_KEY"), os.Getenv("ANTHROPIC_MODEL"))
		}
	}
	return nil
}
