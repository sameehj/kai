package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/sameehj/kai/pkg/types"
)

type sandboxManager struct {
	root      string
	mu        sync.Mutex
	sandboxes map[string]*types.SandboxInfo
}

func newSandboxManager(root string) *sandboxManager {
	return &sandboxManager{
		root:      root,
		sandboxes: make(map[string]*types.SandboxInfo),
	}
}

func (sm *sandboxManager) Ensure(packageID string) (*types.SandboxInfo, error) {
	if sm == nil {
		return nil, nil
	}

	sm.mu.Lock()
	defer sm.mu.Unlock()

	if info, ok := sm.sandboxes[packageID]; ok {
		return info, nil
	}

	if sm.root == "" {
		return nil, fmt.Errorf("sandbox root not configured")
	}

	safeID := sanitizeSandboxID(packageID)
	base := filepath.Join(sm.root, "sandboxes", safeID)
	bpffs := filepath.Join(base, "bpffs")

	if err := os.MkdirAll(bpffs, 0o755); err != nil {
		return nil, fmt.Errorf("prepare sandbox directories: %w", err)
	}

	info := &types.SandboxInfo{
		PackageID:    packageID,
		Root:         base,
		BPFFSPath:    bpffs,
		UIDNamespace: true, // prepared for future user-namespace isolation
		CreatedAt:    time.Now(),
	}
	sm.sandboxes[packageID] = info
	return info, nil
}

func (sm *sandboxManager) Remove(packageID string) {
	if sm == nil {
		return
	}

	sm.mu.Lock()
	defer sm.mu.Unlock()

	info, ok := sm.sandboxes[packageID]
	if !ok {
		return
	}
	delete(sm.sandboxes, packageID)
	_ = os.RemoveAll(info.Root)
}

func sanitizeSandboxID(packageID string) string {
	replacer := strings.NewReplacer("/", "_", "@", "_", ":", "_")
	return replacer.Replace(packageID)
}
