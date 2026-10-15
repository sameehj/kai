package gateway

import (
	"fmt"
	"strings"

	"github.com/kai-agent/kai/internal/config"
)

type Router struct {
	cfg *config.Config
}

func NewRouter(cfg *config.Config) *Router { return &Router{cfg: cfg} }

func (r *Router) SessionKey(userID, channel, target string) string {
	if target == "" {
		target = config.DefaultTargetName(r.cfg.Targets)
	}
	return fmt.Sprintf("%s|%s|%s", userID, channel, target)
}

func (r *Router) ResolveTarget(in IncomingMsg) string {
	if strings.TrimSpace(in.Target) != "" {
		return in.Target
	}
	return config.DefaultTargetName(r.cfg.Targets)
}
