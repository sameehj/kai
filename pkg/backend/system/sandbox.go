package system

// Sandbox enforces execution guardrails for the system backend.
type Sandbox struct {
    Enabled bool
}

func (s Sandbox) Allow(command string) bool {
    return s.Enabled && command != ""
}
