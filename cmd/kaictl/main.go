package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const (
	defaultServerEndpoint = "http://127.0.0.1:8181/tool"
	defaultIndexURL       = "https://raw.githubusercontent.com/sameehj/kai-recipes/main/recipes/recipes/index.yaml"
)

type responsePayload struct {
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}

var httpClientFactory = func() *http.Client {
	return &http.Client{Timeout: 5 * time.Second}
}

func main() {
	rootCmd := &cobra.Command{
		Use:   "kaictl",
		Short: "Control plane for the KAI runtime",
	}

	rootCmd.PersistentFlags().String("server", defaultServerEndpoint, "MCP server endpoint")
	rootCmd.PersistentFlags().String("index", defaultIndexURL, "Recipe index URL (YAML)")

	rootCmd.AddCommand(
		installCmd(),
		listRemoteCmd(),
		listLocalCmd(),
		removeCmd(),
		loadCmd(),
		attachCmd(),
		streamCmd(),
		unloadCmd(),
	)

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func installCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install <package>",
		Short: "Install an OCI artifact into local storage",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			indexURL := cmd.Flag("index").Value.String()

			name, version, err := splitPackageID(args[0])
			if err != nil {
				return err
			}

			payload := map[string]interface{}{
				"name":    name,
				"version": version,
				"index":   indexURL,
			}

			if _, err := callMCPTool(server, "kai__install_package", payload); err != nil {
				return err
			}

			fmt.Printf("Installed %s@%s\n", name, version)
			return nil
		},
	}
}

func listRemoteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list-remote",
		Short: "List packages available in the remote catalog",
		RunE: func(cmd *cobra.Command, _ []string) error {
			server := cmd.Flag("server").Value.String()
			indexURL := cmd.Flag("index").Value.String()

			payload := map[string]interface{}{
				"index": indexURL,
			}

			result, err := callMCPTool(server, "kai__list_remote", payload)
			if err != nil {
				return err
			}
			fmt.Println(string(result))
			return nil
		},
	}
}

func listLocalCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list-local",
		Short: "List packages installed in local storage",
		RunE: func(cmd *cobra.Command, _ []string) error {
			server := cmd.Flag("server").Value.String()
			result, err := callMCPTool(server, "kai__list_local", map[string]interface{}{})
			if err != nil {
				return err
			}
			fmt.Println(string(result))
			return nil
		},
	}
}

func removeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "remove <package>",
		Short: "Remove an installed package from runtime storage",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			server := cmd.Flag("server").Value.String()
			packageID := args[0]

			payload := map[string]interface{}{
				"package": packageID,
			}

			if _, err := callMCPTool(server, "kai__remove_package", payload); err != nil {
				return err
			}

			fmt.Printf("Removed %s\n", packageID)
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

	client := httpClientFactory()
	resp, err := client.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("call MCP tool: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var payload responsePayload
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			return nil, fmt.Errorf("status %s", resp.Status)
		}
		return nil, fmt.Errorf("%s", payload.Error)
	}

	var payload responsePayload
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return payload.Result, nil
}

func splitPackageID(id string) (string, string, error) {
	parts := strings.SplitN(id, "@", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("invalid package identifier %q", id)
	}
	return parts[0], parts[1], nil
}
