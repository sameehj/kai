package main

import (
	"fmt"
	"os"
	"time"

	"github.com/sameehj/kai/pkg/config"
	"github.com/sameehj/kai/pkg/exec"
	"github.com/sameehj/kai/pkg/mcp"
	"github.com/sameehj/kai/pkg/runtime/logging"
	"github.com/sameehj/kai/pkg/system"
	"github.com/sameehj/kai/pkg/tool"
	"github.com/spf13/pflag"
)

var cfgFile string

func main() {
	pflag.StringVar(&cfgFile, "config", "", "config file (default: ~/.kai/config.yaml)")
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

	execTimeout, _ := time.ParseDuration(cfg.Exec.Timeout)
	executor := &exec.SafeExecutor{
		Timeout:   execTimeout,
		MaxOutput: cfg.Exec.MaxOutput,
		Blocklist: cfg.Exec.Blocklist,
	}

	server := mcp.NewServer(executor, registry, profile)
	logger := logging.New(cfg.LogLevel, os.Getenv("KAI_LOG_FORMAT"))
	server.SetLogger(logger)

	if err := server.ServeStdio(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
