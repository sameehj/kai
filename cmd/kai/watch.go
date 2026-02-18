package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
	"github.com/kai-ai/kai/pkg/models"
)

func newWatchCmd() *cobra.Command {
	var agent string
	var minRisk int
	cmd := &cobra.Command{
		Use:   "watch",
		Short: "Live event stream",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			conn, enc, dec, err := rpcConn(cfg)
			if err != nil {
				return err
			}
			defer conn.Close()

			var aid *models.AgentID
			if agent != "" {
				a := models.AgentID(strings.ToLower(agent))
				aid = &a
			}
			if err := enc.Encode(daemon.RPCRequest{Action: "watch", Agent: aid, MinRisk: minRisk}); err != nil {
				return err
			}
			for {
				var resp daemon.RPCResponse
				if err := dec.Decode(&resp); err != nil {
					return err
				}
				if !resp.OK || resp.Event == nil {
					continue
				}
				ev := resp.Event
				warn := ""
				if len(ev.RiskLabels) > 0 {
					warn = " \u26A0 " + strings.Join(ev.RiskLabels, ", ")
				}
				fmt.Fprintf(os.Stdout, "[%s] %-10s %-12s %-40s risk=%d%s\n", ev.Timestamp.Local().Format("15:04:05"), strings.ToUpper(string(ev.Agent)), ev.ActionType, trim(ev.Target, 40), ev.RiskScore, warn)
			}
		},
	}
	cmd.Flags().StringVar(&agent, "agent", "", "filter by agent")
	cmd.Flags().IntVar(&minRisk, "min-risk", 0, "minimum risk score")
	return cmd
}

func trim(v string, n int) string {
	if len(v) <= n {
		return v
	}
	if n < 4 {
		return v[:n]
	}
	return v[:n-3] + "..."
}
