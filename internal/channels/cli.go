package channels

import (
	"context"
	"fmt"
)

type CLIChannel struct{}

func (c *CLIChannel) Name() string { return "stdout" }

func (c *CLIChannel) Send(_ context.Context, msg Message) error {
	if msg.Title != "" {
		fmt.Printf("[%s] %s\n", level(msg.Severity), msg.Title)
	}
	if msg.Body != "" {
		fmt.Println(msg.Body)
	}
	return nil
}

func (c *CLIChannel) Listen(ctx context.Context) (<-chan Incoming, error) {
	ch := make(chan Incoming)
	go func() {
		defer close(ch)
		<-ctx.Done()
	}()
	return ch, nil
}

func level(s string) string {
	if s == "" {
		return "info"
	}
	return s
}
