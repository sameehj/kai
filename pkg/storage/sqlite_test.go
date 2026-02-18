package storage

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/kai-ai/kai/pkg/models"
)

func TestDB_GetLastSessionAndReplay(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "kai.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	now := time.Now()
	s1 := &models.Session{ID: "cs_one", Agent: models.AgentCursor, StartedAt: now.Add(-2 * time.Minute), LastActivity: now.Add(-1 * time.Minute)}
	s2 := &models.Session{ID: "cs_two", Agent: models.AgentClaude, StartedAt: now.Add(-1 * time.Minute), LastActivity: now}
	if err := db.InsertSession(s1); err != nil {
		t.Fatal(err)
	}
	if err := db.InsertSession(s2); err != nil {
		t.Fatal(err)
	}

	lastAny, err := db.GetLastSession(nil)
	if err != nil {
		t.Fatal(err)
	}
	if lastAny.ID != s2.ID {
		t.Fatalf("expected last session %s, got %s", s2.ID, lastAny.ID)
	}

	agent := models.AgentID(models.AgentCursor)
	lastCursor, err := db.GetLastSession(&agent)
	if err != nil {
		t.Fatal(err)
	}
	if lastCursor.ID != s1.ID {
		t.Fatalf("expected cursor session %s, got %s", s1.ID, lastCursor.ID)
	}

	execEv := &models.ExecEvent{ID: "ev_exec_1", SessionID: s1.ID, Timestamp: now, Command: "git push origin main", Args: []string{"push", "origin", "main"}, RiskScore: 65, RiskLabels: []string{"git push"}}
	netEv := &models.NetEvent{ID: "ev_net_1", SessionID: s1.ID, Timestamp: now, RemoteIP: "1.2.3.4", RemotePort: 443, Protocol: "tcp", RiskScore: 25}
	if err := db.InsertExecEvent(execEv); err != nil {
		t.Fatal(err)
	}
	if err := db.InsertNetEvent(netEv); err != nil {
		t.Fatal(err)
	}

	sf := &models.SessionFile{ID: "sf_1", SessionID: s1.ID, FilePath: "main.go", ChangeType: models.FileModified, LinesAdded: 3, LinesRemoved: 1, SaveCount: 1, FirstSeen: now, LastSeen: now}
	before := []byte("old\n")
	after := []byte("new\nline\n")
	snap := &models.Snapshot{ID: "sn_1", SessionFileID: sf.ID, CapturedAt: now, BeforeText: &before, AfterText: &after, LinesAdded: 2, LinesRemoved: 1, Compressed: false}
	if err := db.UpsertSessionFile(sf, snap); err != nil {
		t.Fatal(err)
	}

	replay, err := db.GetReplay(s1.ID)
	if err != nil {
		t.Fatal(err)
	}
	if replay.Session.ID != s1.ID {
		t.Fatalf("unexpected replay session %s", replay.Session.ID)
	}
	if len(replay.Execs) != 1 || len(replay.NetEvents) != 1 || len(replay.Files) != 1 {
		t.Fatalf("unexpected replay counts exec=%d net=%d files=%d", len(replay.Execs), len(replay.NetEvents), len(replay.Files))
	}
	if _, ok := replay.Snapshots[sf.ID]; !ok {
		t.Fatalf("expected snapshot for session file %s", sf.ID)
	}
}
