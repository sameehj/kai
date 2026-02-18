package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/daemon"
)

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "daemon", Short: "Manage KAI daemon"}
	cmd.AddCommand(&cobra.Command{
		Use:   "start",
		Short: "Start daemon in background",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			st, _ := daemon.RunningStatus(cfg)
			if st.Running {
				fmt.Printf("daemon already running pid=%d\n", st.PID)
				return nil
			}
			bin, err := os.Executable()
			if err != nil {
				return err
			}
			proc := exec.Command(bin, "daemon", "run")
			proc.Stdout = os.Stdout
			proc.Stderr = os.Stderr
			if err := proc.Start(); err != nil {
				return err
			}
			fmt.Printf("daemon started pid=%d\n", proc.Process.Pid)
			return nil
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:    "run",
		Short:  "Run daemon in foreground",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			d, err := daemon.New(cfg)
			if err != nil {
				return err
			}
			return d.Start()
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "stop",
		Short: "Stop daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			pidPath := filepath.Join(filepath.Dir(cfg.Daemon.DBPath), "kai.pid")
			b, err := os.ReadFile(pidPath)
			if err != nil {
				return fmt.Errorf("daemon not running")
			}
			pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
			if pid <= 0 {
				return fmt.Errorf("invalid pid")
			}
			p, err := os.FindProcess(pid)
			if err != nil {
				return err
			}
			if err := p.Signal(syscall.SIGTERM); err != nil {
				return err
			}
			fmt.Println("daemon stop signal sent")
			return nil
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "status",
		Short: "Show daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load("")
			if err != nil {
				return err
			}
			st, err := daemon.RunningStatus(cfg)
			if err != nil {
				return err
			}
			if !st.Running {
				fmt.Println("daemon: stopped")
				return nil
			}
			fmt.Printf("daemon: running pid=%d\n", st.PID)
			return nil
		},
	})
	return cmd
}
