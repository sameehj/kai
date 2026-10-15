package channels

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

type SlackChannel struct {
	WebhookURL string
}

func (s *SlackChannel) Name() string { return "slack" }

func (s *SlackChannel) Send(ctx context.Context, msg Message) error {
	if strings.TrimSpace(s.WebhookURL) == "" {
		return fmt.Errorf("slack webhook not configured")
	}
	payload := map[string]any{"text": msg.Title + "\n" + msg.Body, "blocks": MarkdownToSlackBlocks(msg.Body)}
	b, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, s.WebhookURL, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("slack status %s", resp.Status)
	}
	return nil
}

func (s *SlackChannel) Listen(ctx context.Context) (<-chan Incoming, error) {
	ch := make(chan Incoming)
	go func() { defer close(ch); <-ctx.Done() }()
	return ch, nil
}
