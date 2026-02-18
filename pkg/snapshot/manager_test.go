package snapshot

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
)

func TestManager_SkipsEnvFiles(t *testing.T) {
	tmp := t.TempDir()
	db, err := storage.Open(filepath.Join(tmp, "kai.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	s := &models.Session{ID: "cs_test", Agent: models.AgentCursor, StartedAt: time.Now(), LastActivity: time.Now()}
	if err := db.InsertSession(s); err != nil {
		t.Fatal(err)
	}

	m := NewManager(db, Config{SnapshotEnabled: true, MaxSnapshotSizeBytes: 50 * 1024, SkipExtensions: map[string]struct{}{}})
	envPath := filepath.Join(tmp, ".env")
	if err := os.WriteFile(envPath, []byte("OPENAI_API_KEY=abc"), 0o600); err != nil {
		t.Fatal(err)
	}

	m.OnFileEvent(s.ID, envPath, models.FileModified)
	m.FlushAll()

	r, err := db.GetReplay(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Files) != 0 {
		t.Fatalf("expected no session files for .env snapshot, got %d", len(r.Files))
	}
}
