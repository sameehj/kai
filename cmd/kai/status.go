package main

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
	"github.com/kai-ai/kai/pkg/storage"
)

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show active state",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			st, _ := daemon.RunningStatus(cfg)
			db, err := storage.Open(cfg.Daemon.DBPath)
			if err != nil {
				return err
			}
			defer db.Close()
			sessions, _ := db.GetSessions(10, nil)

			fmt.Println("Active agents:")
			now := time.Now()
			for _, s := range sessions {
				if s.EndedAt == nil && now.Sub(s.LastActivity) < 45*time.Second {
					fmt.Printf("  ● %-12s session=%s active %s\n", stringsUpper(string(s.Agent)), s.ID, now.Sub(s.StartedAt).Truncate(time.Second))
				}
			}
			if st.Running {
				fmt.Printf("\nDaemon: running pid=%d\n", st.PID)
			} else {
				fmt.Println("\nDaemon: stopped")
			}
			return nil
		},
	}
}

func stringsUpper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}
