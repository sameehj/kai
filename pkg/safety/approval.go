package safety

import "context"

// ApprovalWorkflow captures user approval checks.
type ApprovalWorkflow interface {
    Request(ctx context.Context, subject string, payload interface{}) (string, error)
}
