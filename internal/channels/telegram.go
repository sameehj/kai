package channels

import (
	"context"
	"fmt"
)

type TelegramChannel struct {
	BotToken string
}

func (t *TelegramChannel) Name() string { return "telegram" }
func (t *TelegramChannel) Send(_ context.Context, _ Message) error {
	if t.BotToken == "" {
		return fmt.Errorf("telegram token not configured")
	}
	return nil
}
func (t *TelegramChannel) Listen(ctx context.Context) (<-chan Incoming, error) {
	ch := make(chan Incoming)
	go func() { defer close(ch); <-ctx.Done() }()
	return ch, nil
}
