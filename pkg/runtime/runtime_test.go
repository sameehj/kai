package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/sameehj/kai/pkg/types"
)

func TestPackagePath(t *testing.T) {
	t.Parallel()

	rt := &Runtime{
		config: &Config{
			StoragePath: "/var/lib/kai",
		},
	}

	got := rt.packagePath("falco-syscalls", "0.37.0")
	want := "/var/lib/kai/packages/falco-syscalls@0.37.0"
	if got != want {
		t.Fatalf("packagePath returned %q, want %q", got, want)
	}

	gotLatest := rt.packagePath("falco-syscalls", "")
	wantLatest := "/var/lib/kai/packages/falco-syscalls@latest"
	if gotLatest != wantLatest {
		t.Fatalf("packagePath returned %q, want %q", gotLatest, wantLatest)
	}
}

func TestInstallListAndRemovePackage(t *testing.T) {
	t.Parallel()

	tempDir := t.TempDir()
	source := filepath.Join(tempDir, "source")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatalf("mkdir source: %v", err)
	}

	manifest := `apiVersion: kai.package/v1
kind: Package
metadata:
  name: demo
  version: 1.0.0
build:
  output:
    - demo.o
`
	if err := os.WriteFile(filepath.Join(source, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(source, "demo.o"), []byte{0x0}, 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	storagePath := filepath.Join(tempDir, "storage")
	rt := &Runtime{
		config:   &Config{StoragePath: storagePath},
		packages: make(map[string]*types.LoadedPackage),
	}

	if err := rt.InstallPackage("demo@1.0.0", source); err != nil {
		t.Fatalf("install package: %v", err)
	}

	installed, err := rt.ListInstalledPackages()
	if err != nil {
		t.Fatalf("list installed: %v", err)
	}
	if len(installed) != 1 {
		t.Fatalf("expected 1 installed package, got %d", len(installed))
	}

	destArtifact := filepath.Join(storagePath, "packages", "demo@1.0.0", "demo.o")
	if _, err := os.Stat(destArtifact); err != nil {
		t.Fatalf("expected artifact at %s: %v", destArtifact, err)
	}

	if err := rt.RemovePackage("demo@1.0.0"); err != nil {
		t.Fatalf("remove package: %v", err)
	}

	if _, err := os.Stat(destArtifact); !os.IsNotExist(err) {
		t.Fatalf("expected artifact to be removed, stat error: %v", err)
	}
}

func TestInstallFromRemote(t *testing.T) {
	tempDir := t.TempDir()
	source := filepath.Join(tempDir, "artifact")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatalf("mkdir artifact: %v", err)
	}

	if err := os.WriteFile(filepath.Join(source, "manifest.yaml"), []byte(`apiVersion: kai.package/v1
kind: Package
metadata:
  name: demo
  version: 1.0.0
build:
  output:
    - demo.o
`), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(source, "demo.o"), []byte{0x1}, 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	indexPath := filepath.Join(tempDir, "index.yaml")
	indexContent := `packages:
  - name: demo
    version: "1.0.0"
    license: Apache-2.0
    source:
      repo: https://example.invalid/demo.git
      ref: v1.0.0
    oci:
      ref: ghcr.io/example/demo
      digest: sha256:placeholder
`
	if err := os.WriteFile(indexPath, []byte(indexContent), 0o644); err != nil {
		t.Fatalf("write index: %v", err)
	}

	binDir := filepath.Join(tempDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	orasPath := filepath.Join(binDir, "oras")
	if err := os.WriteFile(orasPath, []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write oras stub: %v", err)
	}
	t.Setenv("PATH", fmt.Sprintf("%s:%s", binDir, os.Getenv("PATH")))

	storagePath := filepath.Join(tempDir, "storage")
	rt := &Runtime{
		config: &Config{
			StoragePath: storagePath,
			IndexURL:    indexPath,
		},
		packages: make(map[string]*types.LoadedPackage),
		execRunner: func(_ string, args ...string) *exec.Cmd {
			dest := ""
			for i := 0; i < len(args); i++ {
				if args[i] == "-o" && i+1 < len(args) {
					dest = args[i+1]
					break
				}
			}
			if dest == "" {
				dest = filepath.Join(tempDir, "oras-pull")
			}
			script := fmt.Sprintf("set -euo pipefail; mkdir -p %q; cp -r %s/. %q/", dest, source, dest)
			return exec.Command("bash", "-lc", script)
		},
	}

	if err := rt.InstallFromRemote("", "demo", "1.0.0"); err != nil {
		t.Fatalf("install from remote: %v", err)
	}

	destArtifact := filepath.Join(storagePath, "packages", "demo@1.0.0", "demo.o")
	if _, err := os.Stat(destArtifact); err != nil {
		t.Fatalf("expected artifact at %s: %v", destArtifact, err)
	}
}
