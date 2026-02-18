package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
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
			resp, err := rpcCall(cfg, daemon.RPCRequest{Action: "report"})
			if err != nil {
				return err
			}
			_ = last
			rows := resp.Report
			sort.Slice(rows, func(i, j int) bool { return strings.ToUpper(rows[i].Agent) < strings.ToUpper(rows[j].Agent) })
			fmt.Println("AGENT      SESSIONS   FILE_OPS   EXECS   MAX_RISK")
			for _, row := range rows {
				fmt.Printf("%-10s %-10d %-10d %-7d %-8d\n", strings.ToUpper(row.Agent), row.Sessions, row.FileOps, row.Execs, row.MaxRisk)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&last, "last", "1h", "time window (reserved)")
	return cmd
}
