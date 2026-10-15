package agent

import (
	"path/filepath"
	"testing"

	"github.com/kai-agent/kai/internal/llm"
)

func TestSessionAppendAndMessages(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenSession(filepath.Join(dir, "sessions", "default.jsonl"))
	if err != nil {
		t.Fatalf("open session: %v", err)
	}
	defer s.Close()

	if err := s.Append(llm.Message{Role: llm.RoleUser, Content: "hello"}); err != nil {
		t.Fatalf("append user: %v", err)
	}
	if err := s.Append(llm.Message{Role: llm.RoleAssist, Content: "world"}); err != nil {
		t.Fatalf("append assistant: %v", err)
	}

	msgs, err := s.Messages()
	if err != nil {
		t.Fatalf("messages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}
	if msgs[0].Content != "hello" || msgs[1].Content != "world" {
		t.Fatalf("unexpected messages: %+v", msgs)
	}
}
