package windows

import (
	"context"

	"github.com/kai-ai/kai/pkg/models"
)

type collector struct{}

func New() *collector { return &collector{} }

func (c *collector) Start(ctx context.Context, out chan<- models.RawEvent) error {
	<-ctx.Done()
	return nil
}
