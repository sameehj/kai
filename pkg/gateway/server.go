package gateway

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sameehj/kai/pkg/agent"
	"github.com/sameehj/kai/pkg/session"
)

type Server struct {
	addr    string
	runtime *agent.Runtime
	started time.Time
}

type Message struct {
	SessionID string `json:"session_id"`
	Content   string `json:"content"`
}

type Response struct {
	Content string `json:"content"`
	Error   string `json:"error,omitempty"`
}

func NewServer(addr string, runtime *agent.Runtime) *Server {
	return &Server{addr: addr, runtime: runtime}
}

func (s *Server) Start(ctx context.Context) error {
	s.started = time.Now()
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWebSocket)
	mux.HandleFunc("/health", s.handleHealth)
	server := &http.Server{Addr: s.addr, Handler: mux}

	go func() {
		<-ctx.Done()
		_ = server.Shutdown(context.Background())
	}()
	return server.ListenAndServe()
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	upgrader := websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true
		},
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	for {
		var msg Message
		if err := conn.ReadJSON(&msg); err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		resp, err := s.runtime.HandleMessage(ctx, session.SessionID(msg.SessionID), msg.Content)
		cancel()
		if err != nil {
			_ = conn.WriteJSON(Response{Error: err.Error()})
			continue
		}
		_ = conn.WriteJSON(Response{Content: resp})
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	resp := map[string]interface{}{
		"status":         "ok",
		"uptime_seconds": int(time.Since(s.started).Seconds()),
		"version":        "0.1.0",
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}
