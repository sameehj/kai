package channels

import (
	"context"
	"strings"
)

type MultiDispatcher struct {
	Default Channel
	Slack   Channel
	TG      Channel
	Email   Channel
}

func (d *MultiDispatcher) Send(ctx context.Context, msg Message) error {
	ch, route := pickChannel(msg.Channel)
	msg.Channel = route
	switch ch {
	case "slack":
		if d.Slack != nil {
			return d.Slack.Send(ctx, msg)
		}
	case "telegram":
		if d.TG != nil {
			return d.TG.Send(ctx, msg)
		}
	case "email":
		if d.Email != nil {
			return d.Email.Send(ctx, msg)
		}
	default:
		if d.Default != nil {
			return d.Default.Send(ctx, msg)
		}
	}
	if d.Default != nil {
		return d.Default.Send(ctx, msg)
	}
	return nil
}

func pickChannel(spec string) (string, string) {
	spec = strings.TrimSpace(spec)
	if spec == "" || spec == "stdout" {
		return "stdout", "stdout"
	}
	if strings.Contains(spec, ":") {
		kind, route, _ := strings.Cut(spec, ":")
		return strings.ToLower(strings.TrimSpace(kind)), strings.TrimSpace(route)
	}
	return strings.ToLower(spec), spec
}
