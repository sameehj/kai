package llm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

type codexAuthFile struct {
	OpenAIAPIKey *string `json:"OPENAI_API_KEY"`
	Tokens       struct {
		AccessToken string `json:"access_token"`
	} `json:"tokens"`
}

// OpenAIAccountLoginAvailable reports whether Codex account-login credentials
// are available locally and can be used as an OpenAI bearer token fallback.
func OpenAIAccountLoginAvailable() bool {
	token, _ := openAIBearerFromCodexAuth()
	return token != ""
}

func openAIBearerFromCodexAuth() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return openAIBearerFromCodexAuthPath(filepath.Join(home, ".codex", "auth.json"))
}

func openAIBearerFromCodexAuthPath(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var auth codexAuthFile
	if err := json.Unmarshal(data, &auth); err != nil {
		return "", err
	}
	if auth.OpenAIAPIKey != nil {
		if v := strings.TrimSpace(*auth.OpenAIAPIKey); v != "" {
			return v, nil
		}
	}
	if v := strings.TrimSpace(auth.Tokens.AccessToken); v != "" {
		return v, nil
	}
	return "", nil
}
