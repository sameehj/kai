package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sameehj/kai/pkg/config"
	"github.com/sameehj/kai/pkg/exec"
	"github.com/sameehj/kai/pkg/gateway"
	"github.com/sameehj/kai/pkg/mcp"
	"github.com/sameehj/kai/pkg/runtime/logging"
	"github.com/sameehj/kai/pkg/runtime/toolwatcher"
	"github.com/sameehj/kai/pkg/system"
	"github.com/sameehj/kai/pkg/tool"
	"github.com/spf13/cobra"
)

var cfgFile string

func main() {
	root := &cobra.Command{
		Use:   "kai",
		Short: "KAI tool gateway",
	}
	root.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default: ~/.kai/config.yaml)")

	root.AddCommand(gatewayCmd())
	root.AddCommand(toolsCmd())
	root.AddCommand(doctorCmd())

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

func gatewayCmd() *cobra.Command {
	var addr string
	var maxSessions int

	cmd := &cobra.Command{
		Use:   "gateway",
		Short: "Start the gateway",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.LoadConfig(cfgFile)
			if err != nil {
				return err
			}
			profile, _ := system.Detect()
			registry := tool.NewRegistry(cfg.Tools.Paths, profile)
			if err := registry.Load(); err != nil {
				return err
			}

			execTimeout, _ := time.ParseDuration(cfg.Exec.Timeout)
			executor := &exec.SafeExecutor{
				Timeout:   execTimeout,
				MaxOutput: cfg.Exec.MaxOutput,
				Blocklist: cfg.Exec.Blocklist,
			}

			mcpServer := mcp.NewServer(executor, registry, profile)
			if addr == "" {
				addr = cfg.Gateway.Address
			}
			gw := gateway.NewServer(addr, mcpServer, gateway.AllowlistAuthorizer{Allowed: cfg.Gateway.AllowedAddrs})
			if maxSessions == 0 {
				maxSessions = cfg.Gateway.MaxSessions
			}
			if maxSessions > 0 {
				gw.SetMaxSessions(maxSessions)
			}

			logger := logging.New(cfg.LogLevel, os.Getenv("KAI_LOG_FORMAT"))
			mcpServer.SetLogger(logger)
			gw.SetLogger(logger)

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			for _, path := range cfg.Tools.Paths {
				watcher := toolwatcher.New(registry, path)
				watcher.SetLogger(logger)
				go func(w *toolwatcher.Watcher) {
					if err := w.Start(ctx); err != nil && err != context.Canceled {
						fmt.Fprintln(os.Stderr, err)
					}
				}(watcher)
			}

			go func() {
				if err := gw.Start(ctx); err != nil && err != context.Canceled {
					fmt.Fprintln(os.Stderr, err)
					cancel()
				}
			}()

			fmt.Printf("kai-gateway listening on %s\n", gw.Addr())
			waitForSignal()
			cancel()
			return nil
		},
	}

	cmd.Flags().StringVar(&addr, "addr", "", "gateway listen address")
	cmd.Flags().IntVar(&maxSessions, "max-sessions", 0, "maximum concurrent sessions (0 = unlimited)")
	return cmd
}

func toolsCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "tools", Short: "Tool management"}
	cmd.AddCommand(toolsListCmd())
	cmd.AddCommand(toolsGetCmd())
	cmd.AddCommand(toolsCreateCmd())
	return cmd
}

func toolsListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List tools",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.LoadConfig(cfgFile)
			if err != nil {
				return err
			}
			profile, _ := system.Detect()
			registry := tool.NewRegistry(cfg.Tools.Paths, profile)
			if err := registry.Load(); err != nil {
				return err
			}

			tools := registry.List()
			for _, t := range tools {
				status := "available"
				if !t.Metadata.Available {
					status = "unavailable: " + t.Metadata.Reason
				}
				fmt.Printf("%s\t%s\n", t.Name, status)
			}
			return nil
		},
	}
}

func toolsGetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "get NAME",
		Short: "Show TOOL.md",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.LoadConfig(cfgFile)
			if err != nil {
				return err
			}
			profile, _ := system.Detect()
			registry := tool.NewRegistry(cfg.Tools.Paths, profile)
			if err := registry.Load(); err != nil {
				return err
			}

			item, ok := registry.Get(args[0])
			if !ok {
				return fmt.Errorf("tool not found: %s", args[0])
			}
			fmt.Print(item.Content)
			return nil
		},
	}
}

func toolsCreateCmd() *cobra.Command {
	var content string
	cmd := &cobra.Command{
		Use:   "create NAME",
		Short: "Create a tool directory",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.LoadConfig(cfgFile)
			if err != nil {
				return err
			}
			profile, _ := system.Detect()
			registry := tool.NewRegistry(cfg.Tools.Paths, profile)
			if err := registry.Load(); err != nil {
				return err
			}

			toolItem, err := registry.Create(args[0], content)
			if err != nil {
				return err
			}
			fmt.Printf("created %s at %s\n", toolItem.Name, toolItem.Path)
			return nil
		},
	}
	cmd.Flags().StringVar(&content, "content", "", "TOOL.md content")
	return cmd
}

func doctorCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Show system info and tool status",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.LoadConfig(cfgFile)
			if err != nil {
				return err
			}
			profile, _ := system.Detect()
			registry := tool.NewRegistry(cfg.Tools.Paths, profile)
			if err := registry.Load(); err != nil {
				return err
			}
			fmt.Printf("OS: %s\nDistro: %s %s\nKernel: %s\nArch: %s\nShell: %s\nSecurity: %s\n",
				profile.OS, profile.Distro, profile.Version, profile.Kernel, profile.Arch, profile.Shell, profile.SecurityModel)
			fmt.Printf("Tools loaded: %d\n", len(registry.List()))
			fmt.Printf("Gateway: %s\n", cfg.Gateway.Address)
			return nil
		},
	}
}

func waitForSignal() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}
