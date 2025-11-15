package runtime

import (
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/sameehj/kai/internal/attach"
	"github.com/sameehj/kai/internal/chain"
	"github.com/sameehj/kai/internal/loader"
	"github.com/sameehj/kai/pkg/kcp"
	"github.com/sameehj/kai/pkg/policy"
	"github.com/sameehj/kai/pkg/types"
	"gopkg.in/yaml.v3"
)

// Runtime coordinates package loading, chain wiring, and kernel attachment.
type Runtime struct {
	config *Config

	loader     packageLoader
	chain      chainManager
	attach     attacher
	execRunner func(string, ...string) *exec.Cmd
	policy     *policy.Engine
	sandboxes  *sandboxManager
	kernel     *kcp.Profile

	mu       sync.RWMutex
	packages map[string]*types.LoadedPackage
}

type packageLoader interface {
	LoadPackage(string) (*types.LoadedPackage, error)
	Profile() *kcp.Profile
}

type chainManager interface {
	WireChain(*types.LoadedPackage, types.ChainDef) (*types.Chain, error)
	DeleteChain(string)
}

type attacher interface {
	AttachProgram(*ebpf.Program, attach.Options) (link.Link, error)
	Detach(link.Link) error
}

type Config struct {
	StoragePath string
	PolicyPath  string
	IndexURL    string
}

func defaultStoragePath(cfg *Config) string {
	if cfg != nil && cfg.StoragePath != "" {
		return cfg.StoragePath
	}
	if env := os.Getenv("KAI_ROOT"); env != "" {
		return env
	}
	return "/tmp/kai"
}

// InstalledPackage describes a package residing in runtime storage.
type InstalledPackage struct {
	Name      string
	Version   string
	PackageID string
	Path      string
}

// RemotePackage reflects a package entry from the recipe index.
type RemotePackage struct {
	Name    string `json:"name" yaml:"name"`
	Version string `json:"version" yaml:"version"`
	License string `json:"license" yaml:"license"`
	Source  struct {
		Repo string `json:"repo" yaml:"repo"`
		Ref  string `json:"ref" yaml:"ref"`
	} `json:"source"`
	OCI struct {
		Ref    string `json:"ref" yaml:"ref"`
		Digest string `json:"digest" yaml:"digest"`
	} `json:"oci"`
}

// ValidationInput describes a policy validation request.
type ValidationInput struct {
	PackageID    string
	ManifestPath string
}

// ValidationResult captures findings from policy evaluation.
type ValidationResult struct {
	Package    string   `json:"package"`
	Passed     bool     `json:"passed"`
	Violations []string `json:"violations"`
}

func NewRuntime(cfg *Config) (*Runtime, error) {
	var (
		policyEngine *policy.Engine
		err          error
	)

	cfg.StoragePath = defaultStoragePath(cfg)

	if cfg.PolicyPath != "" {
		policyEngine, err = policy.NewEngine(cfg.PolicyPath)
		if err != nil {
			return nil, fmt.Errorf("initialise policy engine: %w", err)
		}
	}

	pkgLoader, err := loader.NewLoader(policyEngine)
	if err != nil {
		return nil, fmt.Errorf("initialise loader: %w", err)
	}

	rt := &Runtime{
		config:     cfg,
		loader:     pkgLoader,
		chain:      chain.NewManager(),
		attach:     attach.NewManager(),
		packages:   make(map[string]*types.LoadedPackage),
		execRunner: exec.Command,
		policy:     policyEngine,
		sandboxes:  newSandboxManager(cfg.StoragePath),
		kernel:     pkgLoader.Profile(),
	}

	return rt, nil
}

func (rt *Runtime) packagePath(name, version string) string {
	if version == "" {
		version = "latest"
	}
	return filepath.Join(rt.config.StoragePath, "packages", fmt.Sprintf("%s@%s", name, version))
}

// LoadPackage loads or reuses a package manifest from disk.
func (rt *Runtime) LoadPackage(name, version string) (*types.LoadedPackage, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	packageID := fmt.Sprintf("%s@%s", name, version)
	if pkg, ok := rt.packages[packageID]; ok {
		return pkg, nil
	}

	path := rt.packagePath(name, version)
	pkg, err := rt.loader.LoadPackage(path)
	if err != nil {
		return nil, fmt.Errorf("load package %s: %w", packageID, err)
	}

	if err := rt.ensureSandbox(packageID, pkg); err != nil {
		rt.releasePackageResources(pkg)
		return nil, fmt.Errorf("prepare sandbox: %w", err)
	}

	rt.packages[packageID] = pkg
	return pkg, nil
}

// AttachOptions controls how a package is attached.
type AttachOptions struct {
	CgroupPath string
	Interface  string
	Parameters map[string]interface{}
}

// AttachPackage wires the chain (if any) and attaches the entry program.
func (rt *Runtime) AttachPackage(packageID string, opts AttachOptions) error {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	pkg, ok := rt.packages[packageID]
	if !ok {
		return fmt.Errorf("package %s not loaded", packageID)
	}

	manifest := pkg.Manifest
	if manifest == nil {
		return fmt.Errorf("package manifest not available")
	}

	if rt.policy != nil {
		req := policy.AttachRequest{
			PackageID:  packageID,
			Package:    manifest,
			CgroupPath: opts.CgroupPath,
			Interface:  opts.Interface,
			Sandbox:    pkg.Sandbox,
		}
		if err := rt.policy.ValidateAttach(req); err != nil {
			return fmt.Errorf("policy attach: %w", err)
		}
	}

	if manifest.Interface.Chain.Entry != "" {
		if _, err := rt.chain.WireChain(pkg, manifest.Interface.Chain); err != nil {
			return fmt.Errorf("wire chain: %w", err)
		}
	}

	entryID := manifest.Interface.Chain.Entry
	if entryID == "" {
		if len(manifest.Interface.Programs) == 0 {
			return fmt.Errorf("no programs available to attach")
		}
		entryID = manifest.Interface.Programs[0].ID
	}

	entryProgram, ok := pkg.Programs[entryID]
	if !ok {
		return fmt.Errorf("entry program %s not found", entryID)
	}

	var entryDef *types.ProgramDef
	for i := range manifest.Interface.Programs {
		if manifest.Interface.Programs[i].ID == entryID {
			entryDef = &manifest.Interface.Programs[i]
			break
		}
	}
	if entryDef == nil {
		return fmt.Errorf("program definition for %s missing", entryID)
	}

	link, err := rt.attach.AttachProgram(entryProgram, attach.Options{
		Type:      entryDef.Type,
		AttachTo:  entryDef.AttachTo,
		Interface: opts.Interface,
		Cgroup:    opts.CgroupPath,
	})
	if err != nil {
		return fmt.Errorf("attach program: %w", err)
	}

	pkg.Links = append(pkg.Links, link)
	pkg.Status = types.StatusAttached
	return nil
}

// StreamEvents consumes ring buffer entries and returns raw events for higher layers to decode.
func (rt *Runtime) StreamEvents(packageID, bufferName string, limit int) ([]map[string]interface{}, error) {
	rt.mu.RLock()
	pkg, ok := rt.packages[packageID]
	rt.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("package %s not loaded", packageID)
	}

	buffer, ok := pkg.Maps[bufferName]
	if !ok {
		return nil, fmt.Errorf("map %s not found", bufferName)
	}

	reader, err := ringbuf.NewReader(buffer)
	if err != nil {
		return nil, fmt.Errorf("create ringbuf reader: %w", err)
	}
	defer reader.Close()

	if limit <= 0 {
		limit = 100
	}

	events := make([]map[string]interface{}, 0, limit)
	for i := 0; i < limit; i++ {
		record, err := reader.Read()
		if err != nil {
			break
		}
		event := map[string]interface{}{
			"raw": record.RawSample,
			"ts":  time.Now(),
		}
		events = append(events, event)
	}

	return events, nil
}

// UnloadPackage detaches, closes, and removes a loaded package.
func (rt *Runtime) UnloadPackage(packageID string) error {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	pkg, ok := rt.packages[packageID]
	if !ok {
		return fmt.Errorf("package %s not loaded", packageID)
	}

	for _, link := range pkg.Links {
		_ = rt.attach.Detach(link)
	}
	if pkg.ChainID != "" {
		rt.chain.DeleteChain(pkg.ChainID)
	}
	for _, prog := range pkg.Programs {
		prog.Close()
	}
	for _, m := range pkg.Maps {
		m.Close()
	}
	delete(rt.packages, packageID)
	pkg.Status = types.StatusStopped
	if rt.sandboxes != nil {
		rt.sandboxes.Remove(packageID)
	}
	return nil
}

// ListPackages returns shallow descriptors of currently loaded packages.
func (rt *Runtime) ListPackages() []*types.LoadedPackage {
	rt.mu.RLock()
	defer rt.mu.RUnlock()

	list := make([]*types.LoadedPackage, 0, len(rt.packages))
	for _, pkg := range rt.packages {
		list = append(list, pkg)
	}
	return list
}

// InstallPackage copies a built package into runtime storage.
func (rt *Runtime) InstallPackage(packageID, sourcePath string) error {
	name, version, err := splitPackageID(packageID)
	if err != nil {
		return err
	}

	if rt.config.StoragePath == "" {
		return fmt.Errorf("storage path not configured")
	}

	sourceInfo, err := os.Stat(sourcePath)
	if err != nil {
		return fmt.Errorf("stat source: %w", err)
	}
	if !sourceInfo.IsDir() {
		return fmt.Errorf("source path must be a directory")
	}

	manifestPath := filepath.Join(sourcePath, "manifest.yaml")
	if _, err := os.Stat(manifestPath); err != nil {
		return fmt.Errorf("package manifest not found at %s", manifestPath)
	}

	packagesRoot := filepath.Join(rt.config.StoragePath, "packages")
	if err := os.MkdirAll(packagesRoot, 0o755); err != nil {
		return fmt.Errorf("create storage directory: %w", err)
	}

	destPath := filepath.Join(packagesRoot, fmt.Sprintf("%s@%s", name, version))
	if err := os.RemoveAll(destPath); err != nil {
		return fmt.Errorf("clean destination: %w", err)
	}
	if err := copyDir(sourcePath, destPath); err != nil {
		return fmt.Errorf("copy package: %w", err)
	}
	return nil
}

// RemovePackage deletes an installed package and unloads it if necessary.
func (rt *Runtime) RemovePackage(packageID string) error {
	_, _, err := splitPackageID(packageID)
	if err != nil {
		return err
	}

	// Attempt unload; ignore not-loaded errors.
	if err := rt.UnloadPackage(packageID); err != nil && !strings.Contains(err.Error(), "not loaded") {
		return err
	}

	destPath := filepath.Join(rt.config.StoragePath, "packages", packageID)
	if err := os.RemoveAll(destPath); err != nil {
		return fmt.Errorf("remove package directory: %w", err)
	}
	return nil
}

// ListInstalledPackages enumerates packages present in runtime storage.
func (rt *Runtime) ListInstalledPackages() ([]InstalledPackage, error) {
	packagesRoot := filepath.Join(rt.config.StoragePath, "packages")
	entries, err := os.ReadDir(packagesRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read storage directory: %w", err)
	}

	results := make([]InstalledPackage, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name, version, err := splitPackageID(entry.Name())
		if err != nil {
			continue
		}
		results = append(results, InstalledPackage{
			Name:      name,
			Version:   version,
			PackageID: entry.Name(),
			Path:      filepath.Join(packagesRoot, entry.Name()),
		})
	}
	return results, nil
}

// ListRemotePackages downloads and parses the recipe index.
func (rt *Runtime) ListRemotePackages(indexURL string) ([]RemotePackage, error) {
	if indexURL == "" {
		indexURL = rt.config.IndexURL
	}
	if indexURL == "" {
		return nil, fmt.Errorf("recipe index URL not configured")
	}

	doc, err := loadIndexDocument(indexURL)
	if err != nil {
		return nil, fmt.Errorf("load index: %w", err)
	}

	results := make([]RemotePackage, 0, len(doc.Packages))
	for _, pkg := range doc.Packages {
		entry := RemotePackage{
			Name:    pkg.Name,
			Version: pkg.Version,
			License: pkg.License,
		}
		entry.Source.Repo = pkg.Source.Repo
		entry.Source.Ref = pkg.Source.Ref
		entry.OCI.Ref = pkg.OCI.Ref
		entry.OCI.Digest = pkg.OCI.Digest
		results = append(results, entry)
	}
	return results, nil
}

// ValidatePackage evaluates a manifest against the configured policy engine.
func (rt *Runtime) ValidatePackage(input ValidationInput) (*ValidationResult, error) {
	if rt.policy == nil {
		return nil, fmt.Errorf("policy engine not configured")
	}

	manifestPath := input.ManifestPath
	if manifestPath == "" {
		if input.PackageID == "" {
			return nil, fmt.Errorf("package identifier or manifest path required")
		}
		name, version, err := splitPackageID(input.PackageID)
		if err != nil {
			return nil, err
		}
		manifestPath = filepath.Join(rt.packagePath(name, version), "manifest.yaml")
	}

	manifest, err := parseManifest(manifestPath)
	if err != nil {
		return nil, err
	}

	packagePath := filepath.Dir(manifestPath)
	report := rt.policy.ReportPackage(packagePath, manifest)
	return &ValidationResult{
		Package:    report.Package,
		Passed:     report.Passed,
		Violations: report.Violations,
	}, nil
}

// InspectKernel returns the cached kernel profile or refreshes it if unavailable.
func (rt *Runtime) InspectKernel() (*kcp.Profile, error) {
	rt.mu.RLock()
	if rt.kernel != nil {
		defer rt.mu.RUnlock()
		return rt.kernel, nil
	}
	rt.mu.RUnlock()

	profile, err := kcp.Detect()
	if err != nil {
		return nil, fmt.Errorf("detect kernel: %w", err)
	}

	rt.mu.Lock()
	rt.kernel = profile
	rt.mu.Unlock()
	return profile, nil
}

// InstallFromRemote fetches an artifact referenced in the recipe index and stores it locally.
func (rt *Runtime) InstallFromRemote(indexURL, name, version string) error {
	if indexURL == "" {
		indexURL = rt.config.IndexURL
	}
	if indexURL == "" {
		return fmt.Errorf("recipe index URL not configured")
	}

	doc, err := loadIndexDocument(indexURL)
	if err != nil {
		return fmt.Errorf("load index: %w", err)
	}

	entry, err := doc.find(name, version)
	if err != nil {
		return err
	}
	if entry.OCI.Ref == "" || entry.OCI.Digest == "" {
		return fmt.Errorf("package %s@%s missing OCI reference", name, version)
	}

	orasPath, err := exec.LookPath("oras")
	if err != nil {
		return fmt.Errorf("oras CLI not found in PATH")
	}

	tmpDir, err := os.MkdirTemp("", "kai-oras-*")
	if err != nil {
		return fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	cmd := rt.execRunner(orasPath, "pull", fmt.Sprintf("%s@%s", entry.OCI.Ref, entry.OCI.Digest), "-a", "-o", tmpDir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("oras pull failed: %w", err)
	}

	packageID := fmt.Sprintf("%s@%s", name, version)
	return rt.InstallPackage(packageID, tmpDir)
}

type indexDocument struct {
	Packages []indexPackage `yaml:"packages"`
}

type indexPackage struct {
	Name    string `yaml:"name"`
	Version string `yaml:"version"`
	License string `yaml:"license"`
	Source  struct {
		Repo string `yaml:"repo"`
		Ref  string `yaml:"ref"`
	} `yaml:"source"`
	OCI struct {
		Ref    string `yaml:"ref"`
		Digest string `yaml:"digest"`
	} `yaml:"oci"`
}

func loadIndexDocument(location string) (*indexDocument, error) {
	var data []byte
	var err error
	if strings.HasPrefix(location, "http://") || strings.HasPrefix(location, "https://") {
		resp, reqErr := http.Get(location)
		if reqErr != nil {
			return nil, reqErr
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("index fetch failed: %s", resp.Status)
		}
		data, err = io.ReadAll(resp.Body)
	} else {
		data, err = os.ReadFile(location)
	}
	if err != nil {
		return nil, err
	}

	var doc indexDocument
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	return &doc, nil
}

func (doc *indexDocument) find(name, version string) (*indexPackage, error) {
	for i := range doc.Packages {
		if doc.Packages[i].Name == name && doc.Packages[i].Version == version {
			return &doc.Packages[i], nil
		}
	}
	return nil, fmt.Errorf("package %s@%s not found in index", name, version)
}

func splitPackageID(id string) (string, string, error) {
	parts := strings.SplitN(id, "@", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("invalid package identifier %q", id)
	}
	return parts[0], parts[1], nil
}

func (rt *Runtime) ensureSandbox(packageID string, pkg *types.LoadedPackage) error {
	if rt.sandboxes == nil || pkg == nil {
		return nil
	}
	info, err := rt.sandboxes.Ensure(packageID)
	if err != nil {
		return err
	}
	pkg.Sandbox = info
	return nil
}

func (rt *Runtime) releasePackageResources(pkg *types.LoadedPackage) {
	if pkg == nil {
		return
	}
	for _, link := range pkg.Links {
		_ = rt.attach.Detach(link)
	}
	for _, prog := range pkg.Programs {
		prog.Close()
	}
	for _, m := range pkg.Maps {
		m.Close()
	}
}

func parseManifest(path string) (*types.Package, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest: %w", err)
	}
	var pkg types.Package
	if err := yaml.Unmarshal(data, &pkg); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	return &pkg, nil
}

func copyDir(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}

		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}

		srcFile, err := os.Open(path)
		if err != nil {
			return err
		}
		destFile, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			srcFile.Close()
			return err
		}

		_, copyErr := io.Copy(destFile, srcFile)
		closeDestErr := destFile.Close()
		closeSrcErr := srcFile.Close()

		if copyErr != nil {
			return copyErr
		}
		if closeDestErr != nil {
			return closeDestErr
		}
		if closeSrcErr != nil {
			return closeSrcErr
		}
		return nil
	})
}
