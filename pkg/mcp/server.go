package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/sameehj/kai/pkg/kcp"
	"github.com/sameehj/kai/pkg/runtime"
	"github.com/sameehj/kai/pkg/types"
)

// Server exposes runtime operations over a lightweight MCP-style HTTP bridge.
type Server struct {
	runtime   ToolRuntime
	toolsPath string

	httpServer *http.Server
	mu         sync.Mutex
}

type ToolRuntime interface {
	LoadPackage(name, version string) (*types.LoadedPackage, error)
	AttachPackage(packageID string, opts runtime.AttachOptions) error
	StreamEvents(packageID, buffer string, limit int) ([]map[string]interface{}, error)
	ListPackages() []*types.LoadedPackage
	UnloadPackage(packageID string) error
	InstallFromRemote(indexURL, name, version string) error
	RemovePackage(packageID string) error
	ListInstalledPackages() ([]runtime.InstalledPackage, error)
	ListRemotePackages(indexURL string) ([]runtime.RemotePackage, error)
	ValidatePackage(runtime.ValidationInput) (*runtime.ValidationResult, error)
	InspectKernel() (*kcp.Profile, error)
}

type requestPayload struct {
	Tool   string          `json:"tool"`
	Params json.RawMessage `json:"params"`
}

type responsePayload struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

func NewServer(rt ToolRuntime, toolsPath string) (*Server, error) {
	s := &Server{
		runtime:   rt,
		toolsPath: toolsPath,
	}

	if err := s.generateToolFilesystem(); err != nil {
		return nil, err
	}

	return s, nil
}

func (s *Server) Serve(ctx context.Context, addr string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/tool", s.handleHTTPToolCall)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}
	s.mu.Lock()
	s.httpServer = server
	s.mu.Unlock()

	errCh := make(chan error, 1)
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	case err := <-errCh:
		return err
	}
}

func (s *Server) ServeSTDIO(ctx context.Context, r io.Reader, w io.Writer) error {
	reader := bufio.NewScanner(r)
	encoder := json.NewEncoder(w)

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		if !reader.Scan() {
			if err := reader.Err(); err != nil {
				return err
			}
			return nil
		}

		var req requestPayload
		if err := json.Unmarshal(reader.Bytes(), &req); err != nil {
			if err := encoder.Encode(responsePayload{Error: err.Error()}); err != nil {
				return err
			}
			continue
		}

		result, err := s.HandleToolCall(ctx, req.Tool, req.Params)
		if err != nil {
			if err := encoder.Encode(responsePayload{Error: err.Error()}); err != nil {
				return err
			}
			continue
		}

		if err := encoder.Encode(responsePayload{Result: result}); err != nil {
			return err
		}
	}
}

func (s *Server) handleHTTPToolCall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var req requestPayload
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, fmt.Errorf("decode request: %w", err))
		return
	}

	result, err := s.HandleToolCall(r.Context(), req.Tool, req.Params)
	if err != nil {
		writeError(w, err)
		return
	}

	writeResult(w, result)
}

func writeError(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	payload := responsePayload{Error: err.Error()}
	_ = json.NewEncoder(w).Encode(payload)
}

func writeResult(w http.ResponseWriter, result json.RawMessage) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	payload := responsePayload{Result: result}
	if result == nil {
		payload.Result = json.RawMessage([]byte("null"))
	}
	_ = json.NewEncoder(w).Encode(payload)
}

// HandleToolCall routes requests to concrete runtime functions.
func (s *Server) HandleToolCall(ctx context.Context, toolName string, params json.RawMessage) (json.RawMessage, error) {
	switch toolName {
	case "kai__list_remote":
		return s.handleListRemote(ctx, params)
	case "kai__list_local":
		return s.handleListLocal(ctx, params)
	case "kai__install_package":
		return s.handleInstallPackage(ctx, params)
	case "kai__remove_package":
		return s.handleRemovePackage(ctx, params)
	case "kai__load_program":
		return s.handleLoadProgram(ctx, params)
	case "kai__attach_program":
		return s.handleAttachProgram(ctx, params)
	case "kai__stream_events":
		return s.handleStreamEvents(ctx, params)
	case "kai__inspect_state":
		return s.handleInspectState(ctx, params)
	case "kai__inspect_kernel":
		return s.handleInspectKernel(ctx, params)
	case "kai__unload_program":
		return s.handleUnloadProgram(ctx, params)
	case "kai__validate_package":
		return s.handleValidatePackage(ctx, params)
	default:
		return nil, fmt.Errorf("unknown tool: %s", toolName)
	}
}

func (s *Server) handleLoadProgram(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Package string `json:"package"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}

	name, version := parsePackageID(input.Package)
	pkg, err := s.runtime.LoadPackage(name, version)
	if err != nil {
		return nil, err
	}

	response := map[string]interface{}{
		"package_id":      input.Package,
		"programs_loaded": mapKeys(pkg.Programs),
		"maps_created":    mapKeys(pkg.Maps),
		"status":          pkg.Status,
	}
	return json.Marshal(response)
}

func (s *Server) handleAttachProgram(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		PackageID string            `json:"package_id"`
		Namespace map[string]string `json:"namespace"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}

	opts := runtime.AttachOptions{}
	if input.Namespace != nil {
		opts.CgroupPath = input.Namespace["cgroup"]
	}

	if err := s.runtime.AttachPackage(input.PackageID, opts); err != nil {
		return nil, err
	}

	return json.Marshal(map[string]string{
		"status": "attached",
	})
}

func (s *Server) handleStreamEvents(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		PackageID string `json:"package_id"`
		Buffer    string `json:"buffer"`
		Limit     int    `json:"limit"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}

	events, err := s.runtime.StreamEvents(input.PackageID, input.Buffer, input.Limit)
	if err != nil {
		return nil, err
	}
	return json.Marshal(events)
}

func (s *Server) handleInspectState(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
	packages := s.runtime.ListPackages()
	response := make([]map[string]interface{}, 0, len(packages))
	for _, pkg := range packages {
		response = append(response, map[string]interface{}{
			"name":      pkg.Manifest.Metadata.Name,
			"version":   pkg.Manifest.Metadata.Version,
			"status":    pkg.Status,
			"chain_id":  pkg.ChainID,
			"loaded_at": pkg.LoadedAt,
		})
	}
	return json.Marshal(response)
}

func (s *Server) handleInspectKernel(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
	profile, err := s.runtime.InspectKernel()
	if err != nil {
		return nil, err
	}
	return json.Marshal(profile)
}

func (s *Server) handleUnloadProgram(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		PackageID string `json:"package_id"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}

	if err := s.runtime.UnloadPackage(input.PackageID); err != nil {
		return nil, err
	}

	return json.Marshal(map[string]string{
		"status": "unloaded",
	})
}

func (s *Server) handleValidatePackage(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		PackageID    string `json:"package"`
		ManifestPath string `json:"manifest"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}
	if input.PackageID == "" && input.ManifestPath == "" {
		return nil, fmt.Errorf("package or manifest path required")
	}

	result, err := s.runtime.ValidatePackage(runtime.ValidationInput{
		PackageID:    input.PackageID,
		ManifestPath: input.ManifestPath,
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(result)
}

func (s *Server) handleInstallPackage(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Name    string `json:"name"`
		Version string `json:"version"`
		Index   string `json:"index"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}
	if input.Name == "" || input.Version == "" {
		return nil, fmt.Errorf("name and version are required")
	}
	if err := s.runtime.InstallFromRemote(input.Index, input.Name, input.Version); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]string{
		"status":  "installed",
		"name":    input.Name,
		"version": input.Version,
	})
}

func (s *Server) handleRemovePackage(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Package string `json:"package"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}
	if input.Package == "" {
		return nil, fmt.Errorf("package is required")
	}
	if err := s.runtime.RemovePackage(input.Package); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]string{
		"status": "removed",
	})
}

func (s *Server) handleListLocal(_ context.Context, _ json.RawMessage) (json.RawMessage, error) {
	installed, err := s.runtime.ListInstalledPackages()
	if err != nil {
		return nil, err
	}

	loaded := s.runtime.ListPackages()
	loadedMap := make(map[string]*types.LoadedPackage)
	for _, pkg := range loaded {
		if pkg == nil || pkg.Manifest == nil {
			continue
		}
		id := fmt.Sprintf("%s@%s", pkg.Manifest.Metadata.Name, pkg.Manifest.Metadata.Version)
		loadedMap[id] = pkg
	}

	response := make([]map[string]interface{}, 0, len(installed)+len(loaded))
	seen := make(map[string]struct{})

	for _, inst := range installed {
		entry := map[string]interface{}{
			"package_id": inst.PackageID,
			"name":       inst.Name,
			"version":    inst.Version,
			"path":       inst.Path,
			"loaded":     false,
			"status":     "installed",
		}
		if pkg, ok := loadedMap[inst.PackageID]; ok {
			entry["loaded"] = true
			entry["status"] = pkg.Status
		}
		response = append(response, entry)
		seen[inst.PackageID] = struct{}{}
	}

	for id, pkg := range loadedMap {
		if _, ok := seen[id]; ok {
			continue
		}
		entry := map[string]interface{}{
			"package_id": id,
			"name":       pkg.Manifest.Metadata.Name,
			"version":    pkg.Manifest.Metadata.Version,
			"loaded":     true,
			"status":     pkg.Status,
		}
		response = append(response, entry)
	}

	return json.Marshal(response)
}

func (s *Server) handleListRemote(_ context.Context, params json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Index string `json:"index"`
	}
	if err := json.Unmarshal(params, &input); err != nil {
		return nil, err
	}

	packages, err := s.runtime.ListRemotePackages(input.Index)
	if err != nil {
		return nil, err
	}
	return json.Marshal(packages)
}

func (s *Server) generateToolFilesystem() error {
	if s.toolsPath == "" {
		return nil
	}

	base := filepath.Join(s.toolsPath, "servers", "kai")
	if err := os.MkdirAll(base, 0o755); err != nil {
		return fmt.Errorf("create tools directory: %w", err)
	}

	files := map[string]string{
		"list_remote.ts":      typescriptListRemote,
		"list_local.ts":       typescriptListLocal,
		"install_package.ts":  typescriptInstallPackage,
		"remove_package.ts":   typescriptRemovePackage,
		"load_program.ts":     typescriptLoadProgram,
		"attach_program.ts":   typescriptAttachProgram,
		"stream_events.ts":    typescriptStreamEvents,
		"inspect_state.ts":    typescriptInspectState,
		"inspect_kernel.ts":   typescriptInspectKernel,
		"unload_program.ts":   typescriptUnloadProgram,
		"validate_package.ts": typescriptValidatePackage,
	}

	for name, contents := range files {
		path := filepath.Join(base, name)
		if err := os.WriteFile(path, []byte(strings.TrimSpace(contents)+"\n"), 0o644); err != nil {
			return fmt.Errorf("write tool %s: %w", name, err)
		}
	}
	return nil
}

func parsePackageID(input string) (string, string) {
	parts := strings.SplitN(input, "@", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}
	return input, "latest"
}

func mapKeys[M ~map[K]V, K comparable, V any](m M) []K {
	keys := make([]K, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

const shutdownTimeout = 5 * time.Second

var (
	typescriptListRemote = `
import { callMCPTool } from "../../client.js";

export interface RemotePackageEntry {
  name: string;
  version: string;
  license: string;
  source: { repo: string; ref: string };
  oci?: { ref?: string; digest?: string };
}

export async function list_remote(index?: string): Promise<RemotePackageEntry[]> {
  return callMCPTool<RemotePackageEntry[]>('kai__list_remote', index ? { index } : {});
}
`

	typescriptListLocal = `
import { callMCPTool } from "../../client.js";

export interface PackageEntry {
  package_id: string;
  name?: string;
  version?: string;
  path?: string;
  loaded: boolean;
  status: string;
}

export async function list_local(): Promise<PackageEntry[]> {
  return callMCPTool<PackageEntry[]>('kai__list_local', {});
}
`

	typescriptInstallPackage = `
import { callMCPTool } from "../../client.js";

interface InstallPackageInput {
  name: string;
  version: string;
  index?: string;
}

export async function install_package(
  input: InstallPackageInput
): Promise<void> {
  await callMCPTool('kai__install_package', input);
}
`

	typescriptRemovePackage = `
import { callMCPTool } from "../../client.js";

interface RemovePackageInput {
  package: string;
}

export async function remove_package(
  input: RemovePackageInput
): Promise<void> {
  await callMCPTool('kai__remove_package', input);
}
`

	typescriptLoadProgram = `
import { callMCPTool } from "../../client.js";

export interface LoadProgramInput {
  package: string;
}

export interface LoadProgramResponse {
  package_id: string;
  programs_loaded: string[];
  maps_created: string[];
  status: string;
}

export async function load_program(
  input: LoadProgramInput
): Promise<LoadProgramResponse> {
  return callMCPTool<LoadProgramResponse>('kai__load_program', input);
}
`

	typescriptAttachProgram = `
import { callMCPTool } from "../../client.js";

export interface AttachProgramInput {
  package_id: string;
  namespace?: { cgroup?: string };
}

export async function attach_program(
  input: AttachProgramInput
): Promise<void> {
  return callMCPTool('kai__attach_program', input);
}
`

	typescriptStreamEvents = `
import { callMCPTool } from "../../client.js";

export interface StreamEventsInput {
  package_id: string;
  buffer: string;
  limit?: number;
}

export async function stream_events(
  input: StreamEventsInput
): Promise<any[]> {
  return callMCPTool<any[]>('kai__stream_events', input);
}
`

	typescriptInspectState = `
import { callMCPTool } from "../../client.js";

export async function inspect_state(): Promise<any> {
  return callMCPTool('kai__inspect_state', {});
}
`

	typescriptInspectKernel = `
import { callMCPTool } from "../../client.js";

export interface KernelFeature {
  name: string;
  supported: boolean;
  details?: string;
}

export interface KernelProfile {
  version: string;
  features: Record<string, KernelFeature>;
  helpers: Record<string, boolean>;
  btf_paths?: string[];
  unprivileged_bpf?: boolean;
}

export async function inspect_kernel(): Promise<KernelProfile> {
  return callMCPTool<KernelProfile>('kai__inspect_kernel', {});
}
`

	typescriptUnloadProgram = `
import { callMCPTool } from "../../client.js";

export interface UnloadProgramInput {
  package_id: string;
}

export async function unload_program(
  input: UnloadProgramInput
): Promise<void> {
  return callMCPTool('kai__unload_program', input);
}
`

	typescriptValidatePackage = `
import { callMCPTool } from "../../client.js";

interface ValidatePackageInput {
  package?: string;
  manifest?: string;
}

export interface ValidatePackageResult {
  package: string;
  passed: boolean;
  violations: string[];
}

export async function validate_package(
  input: ValidatePackageInput
): Promise<ValidatePackageResult> {
  return callMCPTool<ValidatePackageResult>('kai__validate_package', input);
}
`
)
