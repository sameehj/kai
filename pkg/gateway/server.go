package gateway

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/sameehj/kai/pkg/mcp"
	"log/slog"
)

type Server struct {
	addr        string
	mcpServer   *mcp.Server
	authorizer  Authorizer
	maxSessions int
	logger      *slog.Logger

	mu       sync.Mutex
	sessions map[string]*Session
}

func NewServer(addr string, mcpServer *mcp.Server, authorizer Authorizer) *Server {
	if authorizer == nil {
		authorizer = NoopAuthorizer{}
	}
	return &Server{addr: addr, mcpServer: mcpServer, authorizer: authorizer, sessions: make(map[string]*Session)}
}

func (s *Server) SetLogger(logger *slog.Logger) {
	s.logger = logger
}

func (s *Server) Start(ctx context.Context) error {
	listener, err := net.Listen("tcp", s.addr)
	if err != nil {
		return err
	}
	defer listener.Close()
	s.logInfo("gateway_listening", "addr", s.addr)

	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
			}
			s.logError("accept_failed", "error", err)
			return err
		}

		if s.maxSessions > 0 && s.sessionCount() >= s.maxSessions {
			s.logWarn("session_limit_reached", "remote", conn.RemoteAddr().String(), "limit", s.maxSessions)
			_ = conn.Close()
			continue
		}

		if err := s.authorizer.Allow(ctx, conn.RemoteAddr().String()); err != nil {
			s.logWarn("session_denied", "remote", conn.RemoteAddr().String(), "error", err)
			_ = conn.Close()
			continue
		}

		session := &Session{
			ID:         uuid.NewString(),
			RemoteAddr: conn.RemoteAddr().String(),
			StartedAt:  time.Now(),
		}
		s.register(session)

		go func() {
			defer s.unregister(session.ID)
			s.logInfo("session_start", "id", session.ID, "remote", session.RemoteAddr)
			_ = s.mcpServer.Serve(conn, conn)
			s.logInfo("session_end", "id", session.ID, "remote", session.RemoteAddr)
			_ = conn.Close()
		}()
	}
}

func (s *Server) register(session *Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[session.ID] = session
}

func (s *Server) unregister(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, id)
}

func (s *Server) SetMaxSessions(max int) {
	s.maxSessions = max
}

func (s *Server) sessionCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sessions)
}

func (s *Server) logInfo(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Info(msg, args...)
	}
}

func (s *Server) logWarn(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Warn(msg, args...)
	}
}

func (s *Server) logError(msg string, args ...any) {
	if s.logger != nil {
		s.logger.Error(msg, args...)
	}
}

func (s *Server) ListSessions() []*Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Session, 0, len(s.sessions))
	for _, session := range s.sessions {
		out = append(out, session)
	}
	return out
}

func (s *Server) Addr() string {
	return s.addr
}

func (s *Server) String() string {
	return fmt.Sprintf("gateway(%s)", s.addr)
}
