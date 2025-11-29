package tool

import "context"

// Validator checks tools for correctness before execution.
type Validator interface {
    Validate(ctx context.Context, reg *Registry) error
}

type NoopValidator struct{}

func (NoopValidator) Validate(ctx context.Context, reg *Registry) error {
    return nil
}
