package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/kai-agent/kai/internal/llm"
)

type Session struct {
	mu   sync.Mutex
	f    *os.File
	path string
}

type sessionRecord struct {
	Role    llm.Role `json:"role"`
	Content string   `json:"content"`
}

func OpenSession(path string) (*Session, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	return &Session{f: f, path: path}, nil
}

func (s *Session) Close() error {
	return s.f.Close()
}

func (s *Session) Append(msg llm.Message) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	rec := sessionRecord{Role: msg.Role, Content: msg.Content}
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	if _, err := s.f.Write(append(b, '\n')); err != nil {
		return err
	}
	return s.f.Sync()
}

func (s *Session) Messages() ([]llm.Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	f, err := os.Open(s.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []llm.Message
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var rec sessionRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		out = append(out, llm.Message{Role: rec.Role, Content: rec.Content})
	}
	return out, sc.Err()
}
