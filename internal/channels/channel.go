package channels

import "context"

type Message struct {
	Channel     string
	Title       string
	Body        string
	Severity    string
	Attachments []string
}

type Incoming struct {
	Channel string
	UserID  string
	Text    string
}

type Channel interface {
	Name() string
	Send(ctx context.Context, msg Message) error
	Listen(ctx context.Context) (<-chan Incoming, error)
}

type Dispatcher interface {
	Send(ctx context.Context, msg Message) error
}
