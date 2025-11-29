package safety

import "context"

type NoopSafetyGuard struct{}

func NewNoop() *NoopSafetyGuard { return &NoopSafetyGuard{} }

func (g *NoopSafetyGuard) CheckTool(ctx context.Context, id string) error {
    return nil
}

func (g *NoopSafetyGuard) CheckAction(ctx context.Context, id string) error {
    return nil
}
