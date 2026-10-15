package gateway

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/config"
)

type Gateway struct {
	cfg      *config.Config
	router   *Router
	sessions map[string]*Session
	mu       sync.Mutex
	started  time.Time
	httpSrv  *http.Server
	dispatch channels.Dispatcher
}

func New(cfg *config.Config) *Gateway {
	d := &channels.MultiDispatcher{Default: &channels.CLIChannel{}}
	if cfg.Channels.Slack.Enabled {
		d.Slack = &channels.SlackChannel{WebhookURL: cfg.Channels.Slack.WebhookURL}
	}
	if cfg.Channels.Telegram.Enabled {
		d.TG = &channels.TelegramChannel{BotToken: cfg.Channels.Telegram.BotToken}
	}
	if cfg.Channels.Email.Enabled {
		d.Email = &channels.EmailChannel{SMTPHost: cfg.Channels.Email.SMTPHost}
	}
	return &Gateway{cfg: cfg, router: NewRouter(cfg), sessions: map[string]*Session{}, dispatch: d}
}

func (g *Gateway) Start(ctx context.Context) error {
	g.started = time.Now()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler(g.started))
	g.httpSrv = &http.Server{Addr: g.cfg.Gateway.Addr, Handler: mux}
	_ = os.MkdirAll(config.DefaultRoot(), 0o755)
	_ = os.WriteFile(config.DefaultGatewayPIDPath(), []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644)

	if g.cfg.Heartbeat.Enabled {
		dur := 30 * time.Minute
		if d, err := time.ParseDuration(g.cfg.Heartbeat.Interval); err == nil {
			dur = d
		}
		hb := &Heartbeat{Interval: dur, Config: g.cfg.Heartbeat.Config, Gateway: g}
		go hb.Run(ctx)
	}

	go func() {
		<-ctx.Done()
		_ = g.Stop(context.Background())
	}()
	err := g.httpSrv.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

func (g *Gateway) Stop(ctx context.Context) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	for k, s := range g.sessions {
		_ = s.Close()
		delete(g.sessions, k)
	}
	_ = os.Remove(config.DefaultGatewayPIDPath())
	if g.httpSrv != nil {
		return g.httpSrv.Shutdown(ctx)
	}
	return nil
}

func (g *Gateway) Status() (bool, string) {
	if b, err := os.ReadFile(config.DefaultGatewayPIDPath()); err == nil {
		return true, string(b)
	}
	return false, ""
}

func (g *Gateway) Enqueue(msg IncomingMsg, ctx context.Context) error {
	target := g.router.ResolveTarget(msg)
	key := g.router.SessionKey(msg.UserID, msg.Channel, target)
	g.mu.Lock()
	s, ok := g.sessions[key]
	if !ok {
		var err error
		s, err = NewSession(key, msg.UserID, msg.Channel, target, g.cfg, g.dispatch.Send)
		if err != nil {
			g.mu.Unlock()
			return err
		}
		g.sessions[key] = s
		go s.ProcessLoop(ctx)
	}
	g.mu.Unlock()

	select {
	case s.Queue <- msg:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func PIDPath() string { return filepath.Clean(config.DefaultGatewayPIDPath()) }
