package channels

import (
	"context"
	"fmt"
)

type EmailChannel struct {
	SMTPHost string
}

func (e *EmailChannel) Name() string { return "email" }
func (e *EmailChannel) Send(_ context.Context, _ Message) error {
	if e.SMTPHost == "" {
		return fmt.Errorf("smtp host not configured")
	}
	return nil
}
func (e *EmailChannel) Listen(ctx context.Context) (<-chan Incoming, error) {
	ch := make(chan Incoming)
	go func() { defer close(ch); <-ctx.Done() }()
	return ch, nil
}
