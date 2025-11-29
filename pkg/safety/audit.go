package safety

// AuditRecorder records safety related events.
type AuditRecorder interface {
    Record(event AuditEvent) error
}

// AuditEvent is a placeholder representation of a logged entry.
type AuditEvent struct {
    ID      string
    Subject string
    Action  string
    Result  string
}
