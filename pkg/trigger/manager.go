package trigger

import "context"

type TriggerManager interface {
    Start(ctx context.Context) error
}
