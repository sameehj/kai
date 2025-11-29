package backend

import (
    "context"
)

type BackendCapabilities struct {
    SupportsEBPF    bool
    KernelVersion   string
    AvailableProbes []string
}

type Backend interface {
    GetCapabilities(ctx context.Context) (BackendCapabilities, error)

    RunSensor(ctx context.Context, id string, params map[string]interface{}) (interface{}, error)
    RunAction(ctx context.Context, id string, params map[string]interface{}) (interface{}, error)
}
