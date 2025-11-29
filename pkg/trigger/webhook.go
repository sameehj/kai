package trigger

import "context"

// WebhookTrigger listens to inbound HTTP hooks.
type WebhookTrigger struct{}

func (WebhookTrigger) Start(ctx context.Context) error {
    return nil
}
