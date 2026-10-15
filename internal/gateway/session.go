package gateway

import (
	"context"
	"sync"

	"github.com/kai-agent/kai/internal/agent"
	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/config"
)

type IncomingMsg struct {
	Text    string
	UserID  string
	Channel string
	Target  string
	ReplyTo string
}

type Session struct {
	ID      string
	UserID  string
	Channel string
	Target  string
	Queue   chan IncomingMsg

	cfg      *config.Config
	agent    *agent.Agent
	sendFunc func(context.Context, channels.Message) error
	mu       sync.Mutex
}

func NewSession(id, userID, channel, target string, cfg *config.Config, send func(context.Context, channels.Message) error) (*Session, error) {
	ag, err := agent.NewForTarget(cfg, target)
	if err != nil {
		return nil, err
	}
	return &Session{ID: id, UserID: userID, Channel: channel, Target: target, Queue: make(chan IncomingMsg, 64), cfg: cfg, agent: ag, sendFunc: send}, nil
}

func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.agent != nil {
		return s.agent.Close()
	}
	return nil
}

func (s *Session) ProcessLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-s.Queue:
			resp, err := s.agent.Run(ctx, msg.Text)
			body := resp
			if err != nil {
				body = "Error: " + err.Error()
			}
			if s.sendFunc != nil {
				_ = s.sendFunc(ctx, channels.Message{Channel: msg.Channel, Title: "Kai", Body: body, Severity: "info"})
			}
		}
	}
}
