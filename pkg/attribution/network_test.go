package attribution

import (
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
