package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
)

func newDebugCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "debug", Short: "Debug collector/attribution streams"}
	cmd.AddCommand(newDebugNetCmd())
	cmd.AddCommand(newDebugClassifyCmd())
	return cmd
}

func newDebugNetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "net",
		Short: "Show raw NET_CONNECT events from collector",
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
			if err := enc.Encode(daemon.RPCRequest{Action: "debug_net"}); err != nil {
				return err
			}
			for {
				var resp daemon.RPCResponse
				if err := dec.Decode(&resp); err != nil {
					return err
				}
				if !resp.OK || resp.RawEvent == nil {
					continue
				}
				rev := resp.RawEvent
				proc := rev.ProcessName
				if proc == "" {
					proc = "-"
				}
				fmt.Fprintf(os.Stdout, "[%s] pid=%d proc=%s target=%s\n", rev.Timestamp.Local().Format("15:04:05"), rev.PID, strings.ToUpper(proc), rev.Target)
			}
		},
	}
}

func newDebugClassifyCmd() *cobra.Command {
	var unknownOnly bool
	cmd := &cobra.Command{
		Use:   "classify",
		Short: "Show net events with live attribution decisions",
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
			if err := enc.Encode(daemon.RPCRequest{Action: "debug_classify_net", UnknownOnly: unknownOnly}); err != nil {
				return err
			}
			for {
				var resp daemon.RPCResponse
				if err := dec.Decode(&resp); err != nil {
					return err
				}
				if !resp.OK || resp.Event == nil || resp.RawEvent == nil {
					continue
				}
				ev := resp.Event
				raw := resp.RawEvent
				agent := strings.ToUpper(string(ev.Agent))
				if ev.Agent == "" {
					agent = "UNKNOWN"
				}
				proc := raw.ProcessName
				if proc == "" {
					proc = "-"
				}
				fmt.Fprintf(os.Stdout, "[%s] agent=%-8s pid=%d proc=%s target=%s\n", raw.Timestamp.Local().Format("15:04:05"), agent, raw.PID, strings.ToUpper(proc), raw.Target)
			}
		},
	}
	cmd.Flags().BoolVar(&unknownOnly, "unknown-only", false, "show only unresolved net events")
	return cmd
}
