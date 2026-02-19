package attribution

import (
	"context"
	"testing"
	"time"
)

func TestDNSCache_EndpointSpecificLoopback(t *testing.T) {
	c := NewDNSCache(nil)
	c.SetEndpoint("127.0.0.1", 11434, "localhost:11434", time.Minute)
	c.SetEndpoint("127.0.0.1", 1234, "localhost:1234", time.Minute)

	d1, ok1 := c.ResolveIP("127.0.0.1", 11434)
	if !ok1 || d1 == nil || *d1 != "localhost:11434" {
		t.Fatalf("expected 11434 to map to localhost:11434, got %v %v", d1, ok1)
	}
	d2, ok2 := c.ResolveIP("127.0.0.1", 1234)
	if !ok2 || d2 == nil || *d2 != "localhost:1234" {
		t.Fatalf("expected 1234 to map to localhost:1234, got %v %v", d2, ok2)
	}
}

func TestPreResolveKnownDomains_LocalhostPortScoped(t *testing.T) {
	c := NewDNSCache(nil)
	PreResolveKnownDomains(c)

	// Give async resolvers a brief chance to populate localhost entries.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for {
		if _, ok := c.getEndpoint("127.0.0.1", 1234); ok {
			break
		}
		select {
		case <-ctx.Done():
			t.Skip("localhost pre-resolution not available in this environment")
		default:
			time.Sleep(20 * time.Millisecond)
		}
	}

	// Must not classify arbitrary localhost ports as LM Studio/Ollama.
	if d, ok := c.Get("127.0.0.1"); ok {
		t.Fatalf("expected no IP-wide localhost attribution, got %q", d)
	}
}
