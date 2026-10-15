package gateway

import (
	"bufio"
	"context"
	"os"
	"strings"
	"time"
)

type Heartbeat struct {
	Interval time.Duration
	Config   string
	Gateway  *Gateway
}

// LoadChecks parses heartbeat markdown entries but does not execute them.
// Phase 2 requirement is config parsing only.
func (h *Heartbeat) LoadChecks() []string {
	f, err := os.Open(h.Config)
	if err != nil {
		return nil
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	out := []string{}
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if !strings.HasPrefix(line, "-") {
			continue
		}
		query := strings.TrimSpace(strings.TrimPrefix(line, "-"))
		if query == "" {
			continue
		}
		out = append(out, query)
	}
	return out
}

func (h *Heartbeat) Run(ctx context.Context) {
	if h.Interval <= 0 {
		h.Interval = 30 * time.Minute
	}
	t := time.NewTicker(h.Interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = h.LoadChecks()
		}
	}
}
