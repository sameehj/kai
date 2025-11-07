package version

import "fmt"

var (
	// Version is the semantic version or git describe result.
	Version = "dev"
	// GitCommit is the short git commit hash for this build.
	GitCommit = "unknown"
	// BuildDate is the RFC3339 timestamp when the binary was built.
	BuildDate = "unknown"
)

// String returns a human readable version summary.
func String() string {
	return fmt.Sprintf("%s (commit %s, built %s)", Version, GitCommit, BuildDate)
}
