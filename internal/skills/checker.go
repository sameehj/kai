package skills

import (
	"strings"

	"github.com/kai-agent/kai/internal/executor"
)

func checkAvailability(meta Metadata, probe *executor.ProbeResult) (available bool, degraded bool, missing []string) {
	if probe == nil {
		return true, false, nil
	}
	available = true
	for _, b := range meta.RequiredBins {
		if !probe.Binaries[b] {
			available = false
			missing = append(missing, b)
		}
	}
	if strings.EqualFold(meta.RequiresRoot, "required") && !probe.HasRoot {
		available = false
		missing = append(missing, "root")
	}
	if strings.EqualFold(meta.RequiresRoot, "preferred") && !probe.HasRoot {
		degraded = true
		missing = append(missing, "root(preferred)")
	}
	return
}
