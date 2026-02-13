package policy

import "testing"

func TestDefaultPolicy(t *testing.T) {
	p := Default()
	if !p.IsAllowed("main", "exec") {
		t.Fatalf("expected exec allowed")
	}
	if p.IsAllowed("main", "unknown") {
		t.Fatalf("expected unknown to be blocked")
	}
}
