package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type Store struct {
	baseDir string
}

func NewStore(baseDir string) *Store {
	return &Store{baseDir: baseDir}
}

func (s *Store) Load(id SessionID) (*Session, error) {
	path := filepath.Join(s.baseDir, "sessions", string(id)+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return &Session{
			ID:        id,
			CreatedAt: time.Now(),
			UpdatedAt: time.Now(),
		}, nil
	}

	var sess Session
	if err := json.Unmarshal(data, &sess); err != nil {
		return nil, err
	}
	return &sess, nil
}

func (s *Store) Save(sess *Session) error {
	sess.UpdatedAt = time.Now()
	path := filepath.Join(s.baseDir, "sessions", string(sess.ID)+".json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(sess, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
