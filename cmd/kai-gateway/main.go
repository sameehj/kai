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
	"github.com/spf13/pflag"
)

var (
	cfgFile     string
	addr        string
	maxSessions int
)

func main() {
	pflag.StringVar(&cfgFile, "config", "", "config file (default: ~/.kai/config.yaml)")
	pflag.StringVar(&addr, "addr", "", "gateway listen address")
	pflag.IntVar(&maxSessions, "max-sessions", 0, "maximum concurrent sessions (0 = unlimited)")
	pflag.Parse()

	cfg, err := config.LoadConfig(cfgFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	profile, _ := system.Detect()
	registry := tool.NewRegistry(cfg.Tools.Paths, profile)
	if err := registry.Load(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	execCfg := cfg.Exec
	execTimeout, _ := time.ParseDuration(execCfg.Timeout)
	executor := &exec.SafeExecutor{
		Timeout:   execTimeout,
		MaxOutput: execCfg.MaxOutput,
		Blocklist: execCfg.Blocklist,
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
}

func waitForSignal() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}
