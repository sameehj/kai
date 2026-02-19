package attribution

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
)

func TestClassify_NetEventDoesNotUseStalePIDAgent(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "kai.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	e := NewEngine(db)
	e.pidAgent[12345] = models.AgentOllama

	raw := models.RawEvent{
		Timestamp:   time.Now(),
		PID:         12345,
		ProcessName: "Google Chrome Helper",
		ActionType:  models.ActionNetConnect,
		Target:      "18.97.36.79:443",
		Platform:    "macos",
	}
	got := e.classify(raw, raw.Timestamp)
	if got == models.AgentOllama {
		t.Fatalf("expected net classification not to use stale pid-agent mapping, got %s", got)
	}
}
