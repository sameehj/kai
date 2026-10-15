package agent

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type MemoryStore struct {
	memoryFile string
	dailyRoot  string
}

func NewMemoryStore(memoryFile, dailyRoot string) *MemoryStore {
	return &MemoryStore{memoryFile: memoryFile, dailyRoot: dailyRoot}
}

func (m *MemoryStore) ReadRelevant() (string, error) {
	parts := []string{}
	if b, err := os.ReadFile(m.memoryFile); err == nil {
		t := strings.TrimSpace(string(b))
		if t != "" {
			parts = append(parts, "MEMORY.md:\n"+t)
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}

	entries, err := os.ReadDir(m.dailyRoot)
	if err == nil {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			names = append(names, e.Name())
		}
		sort.Strings(names)
		for i := len(names) - 1; i >= 0 && len(names)-i <= 2; i-- {
			p := filepath.Join(m.dailyRoot, names[i])
			if b, err := os.ReadFile(p); err == nil {
				t := strings.TrimSpace(string(b))
				if t != "" {
					parts = append(parts, names[i]+":\n"+t)
				}
			}
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}

	return strings.Join(parts, "\n\n"), nil
}
