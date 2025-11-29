package trigger

import "context"

// TimerTrigger fires on intervals.
type TimerTrigger struct{}

func (TimerTrigger) Start(ctx context.Context) error {
    return nil
}
