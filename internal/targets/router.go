package targets

import (
	"fmt"

	"github.com/kai-agent/kai/internal/config"
	"github.com/kai-agent/kai/internal/executor"
)

func Build(cfg *config.Config, name string) (executor.Executor, config.Target, error) {
	t, ok := cfg.Targets[name]
	if !ok {
		return nil, config.Target{}, fmt.Errorf("unknown target: %s", name)
	}
	ex, err := executor.BuildExecutor(executor.TargetSpec{Type: t.Type, Host: t.Host, Port: t.Port, User: t.User, KeyFile: t.Key, Container: t.Container})
	return ex, t, err
}
