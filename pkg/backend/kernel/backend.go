package kernel

import (
	"context"
	"errors"

	"github.com/sameehj/kai/pkg/backend"
)

type KernelBackend struct{}

func New() *KernelBackend { return &KernelBackend{} }

func (k *KernelBackend) GetCapabilities(ctx context.Context) (backend.BackendCapabilities, error) {
	return backend.BackendCapabilities{
		SupportsEBPF:    true,
		KernelVersion:   "5.15",
		AvailableProbes: []string{"sched_switch", "tcp_connect"},
	}, nil
}

func (k *KernelBackend) RunSensor(ctx context.Context, id string, p map[string]interface{}) (interface{}, error) {
	return map[string]interface{}{"status": "ok"}, nil
}

func (k *KernelBackend) RunAction(ctx context.Context, id string, p map[string]interface{}) (interface{}, error) {
	return nil, errors.New("kernel backend does not support actions")
}
