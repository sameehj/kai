package onboard

import (
	"context"

	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/executor"
)

func ProbeTarget(ctx context.Context, cfg *config.Config, target string) (*executor.ProbeResult, error) {
	t := cfg.Targets[target]
	ex, err := executor.BuildExecutor(executor.TargetSpec{Type: t.Type, Host: t.Host, Port: t.Port, User: t.User, KeyFile: t.Key, Container: t.Container})
	if err != nil {
		return nil, err
	}
	return executor.Probe(ctx, ex)
}
