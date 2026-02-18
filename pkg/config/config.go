package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Daemon struct {
		DBPath        string `toml:"db_path"`
		LogPath       string `toml:"log_path"`
		RetentionDays int    `toml:"retention_days"`
		SocketPath    string `toml:"socket_path"`
	} `toml:"daemon"`
	Collection struct {
		PollIntervalMS  int  `toml:"poll_interval_ms"`
		ActiveAgentOnly bool `toml:"active_agent_only"`
	} `toml:"collection"`
	Snapshot struct {
		Enabled        bool     `toml:"enabled"`
		MaxFileKB      int      `toml:"max_file_kb"`
		SkipExtensions []string `toml:"skip_extensions"`
	} `toml:"snapshot"`
	Risk struct {
		MinDisplayScore int `toml:"min_display_score"`
	} `toml:"risk"`
	Privacy struct {
		ExtraSkipPaths []string `toml:"extra_skip_paths"`
	} `toml:"privacy"`
	Network struct {
		ExtraAIDomains []string `toml:"extra_ai_domains"`
	} `toml:"network"`
}

func Default() Config {
	home, _ := os.UserHomeDir()
	cfg := Config{}
	cfg.Daemon.DBPath = filepath.Join(home, ".kai", "kai.db")
	cfg.Daemon.LogPath = filepath.Join(home, ".kai", "kai.log")
	cfg.Daemon.RetentionDays = 7
	cfg.Daemon.SocketPath = filepath.Join(home, ".kai", "kai.sock")
	cfg.Collection.PollIntervalMS = 1000
	cfg.Collection.ActiveAgentOnly = true
	cfg.Snapshot.Enabled = true
	cfg.Snapshot.MaxFileKB = 50
	cfg.Snapshot.SkipExtensions = []string{".jpg", ".jpeg", ".png", ".gif", ".mp4", ".zip", ".tar", ".gz", ".wasm", ".so", ".dylib", ".dll", ".exe"}
	cfg.Risk.MinDisplayScore = 0
	return cfg
}

func Load(path string) (Config, error) {
	cfg := Default()
	if path == "" {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, ".kai", "config.toml")
	}
	if _, err := os.Stat(path); err != nil {
		return expand(cfg), nil
	}
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return cfg, err
	}
	return expand(cfg), nil
}

func expand(cfg Config) Config {
	cfg.Daemon.DBPath = expandHome(cfg.Daemon.DBPath)
	cfg.Daemon.LogPath = expandHome(cfg.Daemon.LogPath)
	cfg.Daemon.SocketPath = expandHome(cfg.Daemon.SocketPath)
	return cfg
}

func expandHome(v string) string {
	if strings.HasPrefix(v, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(v, "~/"))
	}
	return v
}
