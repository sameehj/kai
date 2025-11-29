package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Config defines runtime settings for KAI.
type Config struct {
	RecipesPath string `yaml:"recipesPath"`
	LogLevel    string `yaml:"logLevel"`
}

// LoadConfig loads configuration from a YAML file and environment overrides.
func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		RecipesPath: "./recipes",
		LogLevel:    "info",
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

	if recipesPath := os.Getenv("KAI_RECIPES_PATH"); recipesPath != "" {
		cfg.RecipesPath = recipesPath
	}
	if logLevel := os.Getenv("KAI_LOG_LEVEL"); logLevel != "" {
		cfg.LogLevel = logLevel
	}

	if _, err := os.Stat(cfg.RecipesPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("recipes path does not exist: %s", cfg.RecipesPath)
	}

	return cfg, nil
}

// DefaultConfigPath returns the default location for the CLI config file.
func DefaultConfigPath() string {
	if path := os.Getenv("KAI_CONFIG"); path != "" {
		return path
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".kai", "config.yaml")
}
