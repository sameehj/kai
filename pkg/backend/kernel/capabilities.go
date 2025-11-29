package kernel

import (
	"context"

	"github.com/sameehj/kai/pkg/backend"
)

// CapabilityInspector reports kernel specific capabilities.
type CapabilityInspector interface {
	Inspect(ctx context.Context) (backend.BackendCapabilities, error)
}

type StaticInspector struct{}

func (StaticInspector) Inspect(ctx context.Context) (backend.BackendCapabilities, error) {
	return backend.BackendCapabilities{}, nil
}
