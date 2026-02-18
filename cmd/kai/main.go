package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

func main() {
	root := &cobra.Command{Use: "kai", Short: "KAI — AI Agent Monitor"}
	root.AddCommand(newDaemonCmd())
	root.AddCommand(newWatchCmd())
	root.AddCommand(newReplayCmd())
	root.AddCommand(newReportCmd())
	root.AddCommand(newSessionsCmd())
	root.AddCommand(newStatusCmd())
	root.AddCommand(newConfigCmd())
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
