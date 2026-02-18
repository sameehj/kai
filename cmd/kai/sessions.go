package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
)

func newSessionsCmd() *cobra.Command {
	var limit int
	var agent string
	cmd := &cobra.Command{
		Use:   "sessions",
		Short: "List recent sessions",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			db, err := storage.Open(cfg.Daemon.DBPath)
			if err != nil {
				return err
			}
			defer db.Close()
			var aid *models.AgentID
			if agent != "" {
				a := models.AgentID(strings.ToLower(agent))
				aid = &a
			}
			sessions, err := db.GetSessions(limit, aid)
			if err != nil {
				return err
			}
			for _, s := range sessions {
				end := "active"
				if s.EndedAt != nil {
					end = s.EndedAt.Local().Format("15:04:05")
				}
				dur := s.Duration
				if dur == 0 {
					if s.EndedAt != nil {
						dur = s.EndedAt.Sub(s.StartedAt)
					} else {
						dur = time.Since(s.StartedAt)
					}
				}
				fmt.Printf("%s %-8s %s -> %s files:%d exec:%d net:%d risk:%d\n", s.ID, strings.ToUpper(string(s.Agent)), s.StartedAt.Local().Format("15:04:05"), end, s.FileWrites+s.FileCreates+s.FileDeletes, s.ExecCount, s.NetCount, s.MaxRisk)
				_ = dur
			}
			return nil
		},
	}
	cmd.Flags().IntVar(&limit, "limit", 20, "max sessions")
	cmd.Flags().StringVar(&agent, "agent", "", "filter agent")
	return cmd
}
