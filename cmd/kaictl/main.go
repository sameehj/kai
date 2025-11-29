package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/sameehj/kai/pkg/config"
	"github.com/sameehj/kai/pkg/flow"
	"github.com/sameehj/kai/pkg/tool"
	"github.com/spf13/cobra"
)

var (
	cfgFile     string
	recipesPath string
	debugMode   bool
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "kaictl",
		Short: "KAI control CLI",
		Long:  "Command-line interface for managing KAI flows, sensors, and actions",
	}

	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default: ~/.kai/config.yaml)")
	rootCmd.PersistentFlags().StringVar(&recipesPath, "recipes", "./recipes", "path to recipes directory")
	rootCmd.PersistentFlags().BoolVar(&debugMode, "debug", false, "enable verbose debug logging")

	rootCmd.AddCommand(listFlowsCmd())
	rootCmd.AddCommand(runFlowCmd())
	rootCmd.AddCommand(listSensorsCmd())

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func listFlowsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list-flows",
		Short: "List all available flows",
		RunE: func(cmd *cobra.Command, args []string) error {
			registry, err := loadRegistry()
			if err != nil {
				return err
			}

			flows := registry.ListFlows()
			if len(flows) == 0 {
				fmt.Println("No flows found")
				return nil
			}

			fmt.Printf("Found %d flow(s):\n\n", len(flows))
			for _, f := range flows {
				fmt.Printf("  • %s\n", f.Metadata.ID)
				fmt.Printf("    Name: %s\n", f.Metadata.Name)
				fmt.Printf("    Description: %s\n", f.Metadata.Description)
				fmt.Printf("    Steps: %d\n", len(f.Spec.Steps))
				fmt.Println()
			}

			return nil
		},
	}
}

func runFlowCmd() *cobra.Command {
	var outputJSON bool

	cmd := &cobra.Command{
		Use:   "run-flow FLOW_ID",
		Short: "Run a flow",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			flowID := args[0]

			registry, err := loadRegistry()
			if err != nil {
				return err
			}

			runner := flow.NewRunner(registry, debugMode)
			ctx := context.Background()

			run, err := runner.Run(ctx, flowID, nil)
			if err != nil {
				return fmt.Errorf("flow execution failed: %w", err)
			}

			if outputJSON {
				data, _ := json.MarshalIndent(run, "", "  ")
				fmt.Println(string(data))
			} else {
				fmt.Printf("\n📊 Flow Run Summary:\n")
				fmt.Printf("  ID: %s\n", run.ID)
				fmt.Printf("  State: %s\n", run.State)
				fmt.Printf("  Duration: %.2fs\n", run.EndedAt.Sub(run.StartedAt).Seconds())
				fmt.Printf("  Steps: %d\n", len(run.Steps))

				if len(run.Result.Data) > 0 {
					fmt.Printf("\n📈 Results:\n")
					data, _ := json.MarshalIndent(run.Result.Data, "  ", "  ")
					fmt.Printf("  %s\n", string(data))
				}
			}

			return nil
		},
	}

	cmd.Flags().BoolVar(&outputJSON, "json", false, "output as JSON")

	return cmd
}

func listSensorsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list-sensors",
		Short: "List all available sensors",
		RunE: func(cmd *cobra.Command, args []string) error {
			registry, err := loadRegistry()
			if err != nil {
				return err
			}

			_ = registry
			fmt.Println("Sensors listing coming soon...")
			return nil
		},
	}
}

func loadRegistry() (*tool.Registry, error) {
	cfg, err := config.LoadConfig(cfgFile)
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}

	if recipesPath != "" {
		cfg.RecipesPath = recipesPath
	}

	registry := tool.NewRegistry()
	if err := registry.LoadFromPath(cfg.RecipesPath); err != nil {
		return nil, fmt.Errorf("load recipes: %w", err)
	}

	return registry, nil
}
