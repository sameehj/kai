package gateway

import (
	"context"
	"fmt"
	"net"
)

// Authorizer controls incoming gateway connections.
type Authorizer interface {
	Allow(ctx context.Context, remoteAddr string) error
}

type NoopAuthorizer struct{}

func (NoopAuthorizer) Allow(ctx context.Context, remoteAddr string) error {
	_ = ctx
	_ = remoteAddr
	return nil
}

// AllowlistAuthorizer allows only specific remote addresses.
type AllowlistAuthorizer struct {
	Allowed []string
}

func (a AllowlistAuthorizer) Allow(ctx context.Context, remoteAddr string) error {
	_ = ctx
	if len(a.Allowed) == 0 {
		return nil
	}
	host := remoteAddr
	if h, _, err := net.SplitHostPort(remoteAddr); err == nil {
		host = h
	}
	for _, addr := range a.Allowed {
		if addr == remoteAddr || addr == host {
			return nil
		}
	}
	return fmt.Errorf("remote address not allowed: %s", remoteAddr)
}
