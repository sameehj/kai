package executor

import (
	"context"
	"errors"
	"fmt"
	"os"
)

type DockerExecutor struct {
	Container string
	Base      *LocalExecutor
}

func NewDockerExecutor(container string) (*DockerExecutor, error) {
	if container == "" {
		return nil, errors.New("container required")
	}
	return &DockerExecutor{Container: container, Base: NewLocalExecutor()}, nil
}

func (d *DockerExecutor) Run(ctx context.Context, cmd []string) (Result, error) {
	return d.RunWithOpts(ctx, cmd, RunOpts{})
}

func (d *DockerExecutor) RunWithOpts(ctx context.Context, cmd []string, opts RunOpts) (Result, error) {
	wrapped := append([]string{"docker", "exec", d.Container}, cmd...)
	return d.Base.RunWithOpts(ctx, wrapped, opts)
}

func (d *DockerExecutor) Stream(ctx context.Context, cmd []string) (<-chan string, <-chan error, error) {
	wrapped := append([]string{"docker", "exec", d.Container}, cmd...)
	return d.Base.Stream(ctx, wrapped)
}

func (d *DockerExecutor) ReadFile(ctx context.Context, path string) ([]byte, error) {
	res, err := d.Run(ctx, []string{"cat", "--", path})
	if err != nil {
		return nil, err
	}
	if res.ExitCode != 0 {
		return nil, fmt.Errorf("cat failed (%d): %s", res.ExitCode, res.Stderr)
	}
	return []byte(res.Stdout), nil
}

func (d *DockerExecutor) WriteFile(ctx context.Context, path string, data []byte) error {
	// Use docker cp from a local temp file for deterministic cross-shell writes.
	tmpf, err := os.CreateTemp("", "kai-docker-write-*")
	if err != nil {
		return err
	}
	tmp := tmpf.Name()
	_ = tmpf.Close()
	defer os.Remove(tmp)
	if err := d.Base.WriteFile(ctx, tmp, data); err != nil {
		return err
	}
	_, err = d.Base.Run(ctx, []string{"docker", "cp", tmp, d.Container + ":" + path})
	return err
}

func (d *DockerExecutor) Kind() string { return "docker" }
