package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sameehj/kai/pkg/mcp"
	"github.com/sameehj/kai/pkg/runtime"
	"github.com/sameehj/kai/server"
	"github.com/sirupsen/logrus"
	"gopkg.in/yaml.v3"
)

var (
	configPath = flag.String("config", "configs/kai-config.yaml", "Path to runtime configuration file")
	dataRoot   = flag.String("data-root", "", "Path to runtime data directory (overrides config or KAI_ROOT)")
	debug      = flag.Bool("debug", false, "Enable debug logging")
	mcpStdio   = flag.Bool("mcp-stdio", false, "Serve MCP over stdio")
	mcpSocket  = flag.String("mcp-socket", "", "Serve MCP over TCP socket (e.g. 0.0.0.0:7010)")
	mcpHTTP    = flag.String("mcp-http", "", "Serve MCP over HTTP (SSE/JSON-RPC) on host:port")
)

func main() {
	flag.Parse()

	log := logrus.New()
	if *debug {
		log.SetLevel(logrus.DebugLevel)
	}

	var (
		cfg *Config
		err error
	)
	if *configPath == "" {
		cfg = &Config{}
	} else {
		cfg, err = loadConfig(*configPath)
		if err != nil {
			log.Fatalf("load config: %v", err)
		}
	}

	rootPath := resolveDataRoot(cfg, *dataRoot)
	if err := os.MkdirAll(rootPath, 0o755); err != nil {
		log.Fatalf("prepare data root %s: %v", rootPath, err)
	}
	cfg.Storage.Path = rootPath
	if *dataRoot != "" || cfg.MCP.ToolsPath == "" {
		cfg.MCP.ToolsPath = rootPath
	}

	rt, err := runtime.NewRuntime(&runtime.Config{
		StoragePath: rootPath,
		PolicyPath:  cfg.Policy.File,
		IndexURL:    cfg.Recipes.IndexURL,
	})
	if err != nil {
		log.Fatalf("initialise runtime: %v", err)
	}

	mcpServer, err := mcp.NewServer(rt, cfg.MCP.ToolsPath)
	if err != nil {
		log.Fatalf("initialise MCP server: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	errorCh := make(chan error, 3)
	transports := 0

	if *mcpStdio {
		transports++
		go func() {
			log.Info("MCP server running in stdio mode")
			if err := mcpServer.ServeSTDIO(ctx, os.Stdin, os.Stdout); err != nil {
				errorCh <- fmt.Errorf("stdio server error: %w", err)
			}
		}()
	}

	if *mcpSocket != "" {
		listener, err := net.Listen("tcp", *mcpSocket)
		if err != nil {
			log.Fatalf("failed to listen on %s: %v", *mcpSocket, err)
		}
		transports++
		go func() {
			log.Infof("MCP server listening on TCP %s", listener.Addr().String())
			defer listener.Close()
			go func() {
				<-ctx.Done()
				_ = listener.Close()
			}()
			for {
				conn, err := listener.Accept()
				if err != nil {
					select {
					case <-ctx.Done():
						return
					default:
					}
					errorCh <- fmt.Errorf("tcp listener error: %w", err)
					return
				}

				go func(c net.Conn) {
					defer c.Close()
					if err := mcpServer.ServeSTDIO(ctx, c, c); err != nil {
						log.WithError(err).Warn("tcp client session ended with error")
					}
				}(conn)
			}
		}()
	}

	if *mcpHTTP != "" {
		transports++
		go func() {
			log.Infof("MCP server listening over HTTP on %s", *mcpHTTP)
			if err := server.StartMCPHTTP(ctx, rt, mcpServer, *mcpHTTP); err != nil {
				errorCh <- fmt.Errorf("http transport error: %w", err)
			}
		}()
	}

	if transports == 0 {
		go func() {
			log.Infof("MCP server listening on %s", cfg.MCP.ListenAddr)
			if err := mcpServer.Serve(ctx, cfg.MCP.ListenAddr); err != nil {
				errorCh <- fmt.Errorf("http server error: %w", err)
			}
		}()
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	log.Info("kaid started")
	select {
	case <-sigCh:
		log.Info("shutdown signal received")
	case err := <-errorCh:
		if err != nil {
			log.WithError(err).Error("mcp server exited")
		}
	}
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
	Recipes struct {
		IndexURL string `yaml:"index_url"`
	} `yaml:"recipes"`
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

func resolveDataRoot(cfg *Config, override string) string {
	if override != "" {
		return override
	}
	if env := os.Getenv("KAI_ROOT"); env != "" {
		return env
	}
	if cfg != nil && cfg.Storage.Path != "" {
		return cfg.Storage.Path
	}
	return "/tmp/kai"
}
