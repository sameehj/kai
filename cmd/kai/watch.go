package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
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
			conn, err := net.Dial("unix", cfg.Daemon.SocketPath)
			if err != nil {
				return fmt.Errorf("connect daemon: %w", err)
			}
			defer conn.Close()
			dec := json.NewDecoder(conn)
			for {
				var ev models.AgentEvent
				if err := dec.Decode(&ev); err != nil {
					return err
				}
				if minRisk > 0 && ev.RiskScore < minRisk {
					continue
				}
				if agent != "" && !strings.EqualFold(string(ev.Agent), agent) {
					continue
				}
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
	_ = time.Second
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
