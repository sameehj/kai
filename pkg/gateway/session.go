package gateway

import "time"

// Session tracks a single client connection.
type Session struct {
	ID         string
	RemoteAddr string
	StartedAt  time.Time
}
