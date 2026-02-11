package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	LogLevel string        `yaml:"logLevel"`
	Tools    ToolsConfig   `yaml:"tools"`
	Gateway  GatewayConfig `yaml:"gateway"`
	Exec     ExecConfig    `yaml:"exec"`
}

type ToolsConfig struct {
	Paths []string `yaml:"paths"`
}

type GatewayConfig struct {
	Address      string   `yaml:"address"`
	AllowedAddrs []string `yaml:"allowedAddrs"`
	MaxSessions  int      `yaml:"maxSessions"`
}

type ExecConfig struct {
	Timeout   string   `yaml:"timeout"`
	MaxOutput int      `yaml:"maxOutput"`
	Blocklist []string `yaml:"blocklist"`
}

func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		LogLevel: "info",
		Tools: ToolsConfig{
			Paths: []string{},
		},
		Gateway: GatewayConfig{
			Address:     "127.0.0.1:9910",
			MaxSessions: 0,
		},
		Exec: ExecConfig{
			Timeout:   "30s",
			MaxOutput: 1024 * 1024,
			Blocklist: []string{"rm", "dd", "mkfs", "shutdown", "reboot"},
		},
	}

	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read config file: %w", err)
		}
		if err := yaml.Unmarshal(data, cfg); err != nil {
			return nil, fmt.Errorf("parse config: %w", err)
		}
	}

	if addr := os.Getenv("KAI_GATEWAY_ADDR"); addr != "" {
		cfg.Gateway.Address = addr
	}
	if allow := os.Getenv("KAI_GATEWAY_ALLOWED_ADDRS"); allow != "" {
		cfg.Gateway.AllowedAddrs = strings.Split(allow, ",")
	}
	if toolsDir := os.Getenv("KAI_TOOLS_DIR"); toolsDir != "" {
		cfg.Tools.Paths = []string{toolsDir}
	}

	if len(cfg.Tools.Paths) == 0 {
		cfg.Tools.Paths = DefaultToolsPaths()
	}

	return cfg, nil
}

func DefaultConfigPath() string {
	if path := os.Getenv("KAI_CONFIG"); path != "" {
		return path
	}
	return filepath.Join(DefaultConfigDir(), "config.yaml")
}

func DefaultConfigDir() string {
	legacy := legacyDir()
	if legacy != "" {
		return legacy
	}

	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(os.Getenv("HOME"), "Library", "Application Support", "kai")
	case "windows":
		if app := os.Getenv("APPDATA"); app != "" {
			return filepath.Join(app, "kai")
		}
		return filepath.Join(os.Getenv("HOME"), "AppData", "Roaming", "kai")
	default:
		if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
			return filepath.Join(xdg, "kai")
		}
		return filepath.Join(os.Getenv("HOME"), ".config", "kai")
	}
}

func DefaultToolsDir() string {
	legacy := legacyDir()
	if legacy != "" {
		return filepath.Join(legacy, "tools")
	}

	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(os.Getenv("HOME"), "Library", "Application Support", "kai", "tools")
	case "windows":
		if app := os.Getenv("APPDATA"); app != "" {
			return filepath.Join(app, "kai", "tools")
		}
		return filepath.Join(os.Getenv("HOME"), "AppData", "Roaming", "kai", "tools")
	default:
		if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
			return filepath.Join(xdg, "kai", "tools")
		}
		return filepath.Join(os.Getenv("HOME"), ".local", "share", "kai", "tools")
	}
}

func DefaultLogsDir() string {
	legacy := legacyDir()
	if legacy != "" {
		return filepath.Join(legacy, "logs")
	}

	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(os.Getenv("HOME"), "Library", "Logs", "kai")
	case "windows":
		if app := os.Getenv("APPDATA"); app != "" {
			return filepath.Join(app, "kai", "logs")
		}
		return filepath.Join(os.Getenv("HOME"), "AppData", "Roaming", "kai", "logs")
	default:
		if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
			return filepath.Join(xdg, "kai", "logs")
		}
		return filepath.Join(os.Getenv("HOME"), ".local", "share", "kai", "logs")
	}
}

func DefaultToolsPaths() []string {
	paths := []string{}
	if bundled := bundledToolsDir(); bundled != "" {
		paths = append(paths, bundled)
	}
	paths = append(paths, "/usr/local/share/kai/tools")
	paths = append(paths, DefaultToolsDir())
	return paths
}

func bundledToolsDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	binDir := filepath.Dir(exe)
	candidate := filepath.Join(binDir, "..", "tools")
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	return ""
}

func legacyDir() string {
	if home, _ := os.UserHomeDir(); home != "" {
		legacy := filepath.Join(home, ".kai")
		if _, err := os.Stat(legacy); err == nil {
			return legacy
		}
	}
	return ""
}
