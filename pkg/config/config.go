package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config defines runtime settings for KAI.
type Config struct {
	RecipesPath string      `yaml:"recipesPath"`
	LogLevel    string      `yaml:"logLevel"`
	Agent       AgentConfig `yaml:"agent"`
}

// AgentConfig contains AI backend configuration.
type AgentConfig struct {
	Auto        bool   `yaml:"auto"`
	Type        string `yaml:"type"`
	ClaudeModel string `yaml:"claude_model"`
	OpenAIModel string `yaml:"openai_model"`
	GeminiModel string `yaml:"gemini_model"`
	OllamaModel string `yaml:"ollama_model"`
}

// LoadConfig loads configuration from a YAML file and environment overrides.
func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		RecipesPath: "./recipes",
		LogLevel:    "info",
		Agent: AgentConfig{
			Auto: true,
			Type: "",
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

	if recipesPath := os.Getenv("KAI_RECIPES_PATH"); recipesPath != "" {
		cfg.RecipesPath = recipesPath
	}
	if logLevel := os.Getenv("KAI_LOG_LEVEL"); logLevel != "" {
		cfg.LogLevel = logLevel
	}
	if agentType := os.Getenv("KAI_AGENT_TYPE"); agentType != "" {
		cfg.Agent.Type = agentType
	}
	if auto := os.Getenv("KAI_AGENT_AUTO"); auto != "" {
		cfg.Agent.Auto = strings.ToLower(auto) != "false"
	}
	if model := os.Getenv("KAI_CLAUDE_MODEL"); model != "" {
		cfg.Agent.ClaudeModel = model
	}
	if model := os.Getenv("KAI_OPENAI_MODEL"); model != "" {
		cfg.Agent.OpenAIModel = model
	}
	if model := os.Getenv("KAI_GEMINI_MODEL"); model != "" {
		cfg.Agent.GeminiModel = model
	}
	if model := os.Getenv("KAI_OLLAMA_MODEL"); model != "" {
		cfg.Agent.OllamaModel = model
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
