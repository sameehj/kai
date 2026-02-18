package main

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/storage"
)

func newReportCmd() *cobra.Command {
	var last string
	cmd := &cobra.Command{
		Use:   "report",
		Short: "Summary report",
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
			sessions, err := db.GetSessions(200, nil)
			if err != nil {
				return err
			}
			agg := map[string][4]int{}
			for _, s := range sessions {
				k := strings.ToUpper(string(s.Agent))
				v := agg[k]
				v[0]++
				v[1] += s.FileWrites + s.FileCreates + s.FileDeletes
				v[2] += s.ExecCount
				if s.MaxRisk > v[3] {
					v[3] = s.MaxRisk
				}
				agg[k] = v
			}
			_ = last
			fmt.Println("AGENT      SESSIONS   FILE_OPS   EXECS   MAX_RISK")
			for k, v := range agg {
				fmt.Printf("%-10s %-10d %-10d %-7d %-8d\n", k, v[0], v[1], v[2], v[3])
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&last, "last", "1h", "time window (reserved)")
	return cmd
}
