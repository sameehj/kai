package ebpf

import "testing"

func TestManagerBasicLifecycle(t *testing.T) {
	m, err := NewManager()
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	if got := m.List(); len(got) != 0 {
		t.Fatalf("expected no programs, got %v", got)
	}
	if err := m.Shutdown(); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
}

func TestUnsupportedLoadOnNonLinux(t *testing.T) {
	m, err := NewManager()
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	if m.Supported() {
		t.Skip("platform supports eBPF; non-linux behavior not applicable")
	}
	if _, err := m.Load("x", "./x.o"); err == nil {
		t.Fatalf("expected error on unsupported platform")
	}
}
