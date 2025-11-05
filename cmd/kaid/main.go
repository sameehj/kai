package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/yourusername/kai/pkg/mcp"
	"github.com/yourusername/kai/pkg/runtime"
	"gopkg.in/yaml.v3"
)

var (
	configPath = flag.String("config", "configs/kai-config.yaml", "Path to runtime configuration file")
	debug      = flag.Bool("debug", false, "Enable debug logging")
)

func main() {
	flag.Parse()

	log := logrus.New()
	if *debug {
		log.SetLevel(logrus.DebugLevel)
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	rt, err := runtime.NewRuntime(&runtime.Config{
		StoragePath: cfg.Storage.Path,
		PolicyPath:  cfg.Policy.File,
	})
	if err != nil {
		log.Fatalf("initialise runtime: %v", err)
	}

	server, err := mcp.NewServer(rt, cfg.MCP.ToolsPath)
	if err != nil {
		log.Fatalf("initialise MCP server: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		log.Infof("MCP server listening on %s", cfg.MCP.ListenAddr)
		if err := server.Serve(ctx, cfg.MCP.ListenAddr); err != nil {
			log.Fatalf("mcp server error: %v", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	log.Info("kaid started")
	<-sigCh
	log.Info("shutdown signal received")
	cancel()
	time.Sleep(500 * time.Millisecond)
}

type Config struct {
	Storage struct {
		Path string `yaml:"path"`
	} `yaml:"storage"`
	MCP struct {
		ListenAddr string `yaml:"listen_addr"`
		ToolsPath  string `yaml:"tools_path"`
	} `yaml:"mcp"`
	Policy struct {
		File string `yaml:"file"`
	} `yaml:"policy"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return &cfg, nil
}
