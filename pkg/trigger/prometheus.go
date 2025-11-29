package trigger

import "context"

// PrometheusTrigger is a stub for metric based triggers.
type PrometheusTrigger struct{}

func (PrometheusTrigger) Start(ctx context.Context) error {
    return nil
}
