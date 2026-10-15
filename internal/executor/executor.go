package executor

import "context"

type Result struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
	DurationMS int64 `json:"duration_ms,omitempty"`
}

type RunOpts struct {
	TimeoutSeconds int
	Env            map[string]string
	MaxOutputBytes int
}

type Executor interface {
	Run(ctx context.Context, cmd []string) (Result, error)
	RunWithOpts(ctx context.Context, cmd []string, opts RunOpts) (Result, error)
	Stream(ctx context.Context, cmd []string) (<-chan string, <-chan error, error)
	ReadFile(ctx context.Context, path string) ([]byte, error)
	WriteFile(ctx context.Context, path string, data []byte) error
	Kind() string
}
