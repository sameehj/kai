package daemon

import (
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/models"
)

func TestHandleConn_StatusSessionsReplay(t *testing.T) {
	tmp := t.TempDir()
	cfg := config.Default()
	cfg.Daemon.DBPath = filepath.Join(tmp, "kai.db")
	cfg.Daemon.SocketPath = filepath.Join(tmp, "kai.sock")

	d, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer d.store.Close()
	d.start = time.Now().Add(-3 * time.Second)

	s := &models.Session{ID: "cs_test", Agent: models.AgentCursor, StartedAt: time.Now().Add(-2 * time.Second), LastActivity: time.Now()}
	if err := d.store.InsertSession(s); err != nil {
		t.Fatal(err)
	}

	statusResp := runRPC(t, d, RPCRequest{Action: "status"})
	if !statusResp.OK || statusResp.Status == nil || !statusResp.Status.Running {
		t.Fatalf("unexpected status response: %+v", statusResp)
	}

	sessionsResp := runRPC(t, d, RPCRequest{Action: "sessions", Limit: 10})
	if !sessionsResp.OK || len(sessionsResp.Sessions) == 0 {
		t.Fatalf("unexpected sessions response: %+v", sessionsResp)
	}

	replayResp := runRPC(t, d, RPCRequest{Action: "replay", SessionID: s.ID})
	if !replayResp.OK || replayResp.Replay == nil || replayResp.Replay.Session.ID != s.ID {
		t.Fatalf("unexpected replay response: %+v", replayResp)
	}
}

func runRPC(t *testing.T, d *Daemon, req RPCRequest) RPCResponse {
	t.Helper()
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.handleConn(server)
	}()

	enc := json.NewEncoder(client)
	dec := json.NewDecoder(client)
	if err := enc.Encode(req); err != nil {
		t.Fatal(err)
	}
	var resp RPCResponse
	if err := dec.Decode(&resp); err != nil {
		t.Fatal(err)
	}
	client.Close()
	<-done
	return resp
}
