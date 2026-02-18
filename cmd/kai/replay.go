package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
)

func newReplayCmd() *cobra.Command {
	var agent string
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "replay [session-id|last]",
		Short: "Replay session",
		Args:  cobra.MaximumNArgs(1),
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

			id := ""
			if len(args) > 0 && args[0] != "last" {
				id = args[0]
			} else {
				var aid *models.AgentID
				if agent != "" {
					a := models.AgentID(strings.ToLower(agent))
					aid = &a
				}
				s, err := db.GetLastSession(aid)
				if err != nil {
					return err
				}
				id = s.ID
			}

			replay, err := db.GetReplay(id)
			if err != nil {
				return err
			}
			if asJSON {
				b, _ := json.MarshalIndent(replay, "", "  ")
				fmt.Println(string(b))
				return nil
			}
			printReplay(replay)
			return nil
		},
	}
	cmd.Flags().StringVar(&agent, "agent", "", "replay most recent session for agent")
	cmd.Flags().BoolVar(&asJSON, "json", false, "json output")
	return cmd
}

func printReplay(r *storage.ReplayResult) {
	s := r.Session
	end := s.LastActivity
	if s.EndedAt != nil {
		end = *s.EndedAt
	}
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("  %s SESSION   %s   %s – %s\n", strings.ToUpper(string(s.Agent)), s.ID, s.StartedAt.Local().Format("15:04"), end.Local().Format("15:04"))
	if s.RepoRoot != nil {
		branch := ""
		if s.RepoBranch != nil {
			branch = *s.RepoBranch
		}
		fmt.Printf("  Repo: %s   Branch: %s\n", *s.RepoRoot, branch)
	}
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	byType := map[models.FileChangeType][]models.SessionFile{}
	for _, f := range r.Files {
		byType[f.ChangeType] = append(byType[f.ChangeType], f)
	}
	printFiles := func(title string, ct models.FileChangeType) {
		files := byType[ct]
		if len(files) == 0 {
			return
		}
		sort.Slice(files, func(i, j int) bool { return files[i].FilePath < files[j].FilePath })
		fmt.Println(title)
		for _, f := range files {
			fmt.Printf("  %-40s +%d -%d\n", f.FilePath, f.LinesAdded, f.LinesRemoved)
		}
		fmt.Println()
	}
	printFiles("MODIFIED", models.FileModified)
	printFiles("CREATED", models.FileCreated)
	printFiles("DELETED", models.FileDeleted)

	if len(r.Execs) > 0 {
		fmt.Println("EXECUTED")
		for _, e := range r.Execs {
			warn := ""
			if len(e.RiskLabels) > 0 {
				warn = "  ⚠ " + strings.Join(e.RiskLabels, ", ")
			}
			fmt.Printf("  %s%s\n", e.Command, warn)
		}
		fmt.Println()
	}

	if len(r.NetEvents) > 0 {
		fmt.Println("NETWORK")
		for _, n := range r.NetEvents {
			domain := n.RemoteIP
			if n.Domain != nil {
				domain = *n.Domain
			}
			fmt.Printf("  %s:%d\n", domain, n.RemotePort)
		}
		fmt.Println()
	}

	risk := make([]models.ExecEvent, 0)
	for _, e := range r.Execs {
		if e.RiskScore > 0 {
			risk = append(risk, e)
		}
	}
	if len(risk) > 0 {
		fmt.Println("RISK EVENTS")
		for _, e := range risk {
			fmt.Printf("  ⚠  %-40s [%d]\n", e.Command, e.RiskScore)
		}
	}
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}
