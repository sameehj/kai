package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

func newConfigCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "config",
		Short: "Open ~/.kai/config.toml in $EDITOR",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			path := filepath.Join(home, ".kai", "config.toml")
			if _, err := os.Stat(path); err != nil {
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					return err
				}
				if err := os.WriteFile(path, []byte(defaultConfigTOML), 0o600); err != nil {
					return err
				}
			}
			editor := os.Getenv("EDITOR")
			if editor == "" {
				fmt.Println(path)
				return nil
			}
			c := exec.Command(editor, path)
			c.Stdin = os.Stdin
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}
}

const defaultConfigTOML = `[daemon]
db_path = "~/.kai/kai.db"
log_path = "~/.kai/kai.log"
retention_days = 7
socket_path = "~/.kai/kai.sock"

[collection]
poll_interval_ms = 1000
active_agent_only = true

[snapshot]
enabled = true
max_file_kb = 50
skip_extensions = [".jpg", ".jpeg", ".png", ".gif", ".mp4", ".zip", ".tar", ".gz", ".wasm", ".so", ".dylib", ".dll", ".exe"]

[risk]
min_display_score = 0

[privacy]
extra_skip_paths = []

[network]
extra_ai_domains = []
`
