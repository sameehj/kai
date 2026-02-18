package collector

import (
	"context"
	"runtime"

	"github.com/kai-ai/kai/pkg/collector/linux"
	"github.com/kai-ai/kai/pkg/collector/macos"
	"github.com/kai-ai/kai/pkg/collector/windows"
	"github.com/kai-ai/kai/pkg/models"
)

type Collector interface {
	Start(ctx context.Context, out chan<- models.RawEvent) error
}

func NewCollector() Collector {
	switch runtime.GOOS {
	case "darwin":
		return macos.New()
	case "linux":
		return linux.New()
	case "windows":
		return windows.New()
	default:
		return windows.New()
	}
}
