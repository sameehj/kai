package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"
)

const defaultServerEndpoint = "http://127.0.0.1:8181/tool"

type responsePayload struct {
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}

func main() {
	rootCmd := &cobra.Command{
		Use:   "kaictl",
		Short: "Control plane for the KAI runtime",
	}

	rootCmd.PersistentFlags().String("server", defaultServerEndpoint, "MCP server endpoint")

	rootCmd.AddCommand(
		buildCmd(),
		installCmd(),
		loadCmd(),
		attachCmd(),
		streamCmd(),
		listCmd(),
		unloadCmd(),
	)

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func buildCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "build <recipe>",
		Short: "Build a package from recipe",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			recipe := args[0]
			if !filepath.IsAbs(recipe) {
				recipe = filepath.Join("recipes", "recipes", recipe)
			}
			return executeScript(filepath.Join("recipes", "scripts", "build_recipe.sh"), recipe)
		},
	}
}

func installCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install <artifact>",
		Short: "Install a built artifact into runtime storage",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("Install command is not yet implemented (requested artifact: %s)\n", args[0])
			return nil
		},
	}
}

func loadCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "load <package>",
		Short: "Load a package into the runtime",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			payload := map[string]interface{}{
				"package": args[0],
			}
			_, err := callMCPTool(server, "kai__load_program", payload)
			return err
		},
	}
	return cmd
}

func attachCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "attach <package>",
		Short: "Attach a loaded package",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			namespace, _ := cmd.Flags().GetString("namespace")
			payload := map[string]interface{}{
				"package_id": args[0],
				"namespace": map[string]string{
					"cgroup": namespace,
				},
			}
			_, err := callMCPTool(server, "kai__attach_program", payload)
			return err
		},
	}
	cmd.Flags().String("namespace", "", "Cgroup path to scope attachment")
	return cmd
}

func streamCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "stream <package>",
		Short: "Stream events from a package buffer",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			buffer, _ := cmd.Flags().GetString("buffer")
			limit, _ := cmd.Flags().GetInt("limit")

			payload := map[string]interface{}{
				"package_id": args[0],
				"buffer":     buffer,
				"limit":      limit,
			}

			result, err := callMCPTool(server, "kai__stream_events", payload)
			if err != nil {
				return err
			}

			fmt.Println(string(result))
			return nil
		},
	}
	cmd.Flags().String("buffer", "execve_events", "Buffer name to read")
	cmd.Flags().Int("limit", 10, "Number of events to retrieve")
	return cmd
}

func listCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List loaded packages",
		RunE: func(cmd *cobra.Command, _ []string) error {
			server := cmd.Flag("server").Value.String()
			result, err := callMCPTool(server, "kai__inspect_state", map[string]interface{}{})
			if err != nil {
				return err
			}
			fmt.Println(string(result))
			return nil
		},
	}
}

func unloadCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "unload <package>",
		Short: "Unload a package from the runtime",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			payload := map[string]interface{}{
				"package_id": args[0],
			}
			_, err := callMCPTool(server, "kai__unload_program", payload)
			return err
		},
	}
}

func callMCPTool(endpoint, tool string, params interface{}) ([]byte, error) {
	request := map[string]interface{}{
		"tool":   tool,
		"params": params,
	}

	body, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpClient := &http.Client{Timeout: 5 * time.Second}
	resp, err := httpClient.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("call MCP tool: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var payload responsePayload
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			return nil, fmt.Errorf("status %s", resp.Status)
		}
		return nil, fmt.Errorf(payload.Error)
	}

	var payload responsePayload
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return payload.Result, nil
}

func executeScript(script string, args ...string) error {
	cmd := exec.Command(script, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
