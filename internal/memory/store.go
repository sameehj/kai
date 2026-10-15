package memory

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Store struct {
	DBPath string
}

func New(path string) *Store { return &Store{DBPath: path} }

// Ensure is intentionally lightweight for v0.1 scaffolding.
func (s *Store) Ensure() error {
	if s.DBPath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(s.DBPath), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(s.DBPath); os.IsNotExist(err) {
		return os.WriteFile(s.DBPath, []byte("# kai memory\n"), 0o644)
	}
	return nil
}

func (s *Store) Append(entry string) error {
	if err := s.Ensure(); err != nil {
		return err
	}
	f, err := os.OpenFile(s.DBPath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(strings.TrimSpace(entry) + "\n")
	return err
}

func (s *Store) Search(q string) ([]string, error) {
	if s.DBPath == "" {
		return nil, nil
	}
	b, err := os.ReadFile(s.DBPath)
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(strings.ToLower(line), strings.ToLower(q)) {
			out = append(out, line)
		}
	}
	return out, nil
}

func (s *Store) DB() (*sql.DB, error) {
	return nil, fmt.Errorf("sqlite driver not linked in v0.1 scaffold")
}
