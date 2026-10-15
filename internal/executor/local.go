package executor

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"
	"sync"
)

type LocalExecutor struct{}

func NewLocalExecutor() *LocalExecutor { return &LocalExecutor{} }

func (e *LocalExecutor) Kind() string { return "local" }

func (e *LocalExecutor) Run(ctx context.Context, cmd []string) (Result, error) {
	return e.RunWithOpts(ctx, cmd, RunOpts{})
}

func (e *LocalExecutor) RunWithOpts(ctx context.Context, cmd []string, opts RunOpts) (Result, error) {
	if len(cmd) == 0 {
		return Result{}, errors.New("empty command")
	}
	if opts.TimeoutSeconds > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(opts.TimeoutSeconds)*time.Second)
		defer cancel()
	}
	start := time.Now()
	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	if len(opts.Env) > 0 {
		env := os.Environ()
		for k, v := range opts.Env {
			env = append(env, k+"="+v)
		}
		c.Env = env
	}
	stdout, err := c.StdoutPipe()
	if err != nil {
		return Result{}, err
	}
	stderr, err := c.StderrPipe()
	if err != nil {
		return Result{}, err
	}
	if err := c.Start(); err != nil {
		return Result{}, err
	}
	maxOut := opts.MaxOutputBytes
	if maxOut <= 0 {
		maxOut = 512 * 1024
	}
	outB, _ := io.ReadAll(io.LimitReader(stdout, int64(maxOut)))
	errB, _ := io.ReadAll(io.LimitReader(stderr, int64(maxOut)))
	err = c.Wait()
	res := Result{Stdout: string(outB), Stderr: string(errB), ExitCode: 0, DurationMS: time.Since(start).Milliseconds()}
	if err != nil {
		var ex *exec.ExitError
		if errors.As(err, &ex) {
			res.ExitCode = ex.ExitCode()
			return res, nil
		}
		return Result{}, err
	}
	return res, nil
}

func (e *LocalExecutor) Stream(ctx context.Context, cmd []string) (<-chan string, <-chan error, error) {
	if len(cmd) == 0 {
		return nil, nil, errors.New("empty command")
	}

	c := exec.CommandContext(ctx, cmd[0], cmd[1:]...)
	stdout, err := c.StdoutPipe()
	if err != nil {
		return nil, nil, fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := c.StderrPipe()
	if err != nil {
		return nil, nil, fmt.Errorf("stderr pipe: %w", err)
	}

	lines := make(chan string)
	errs := make(chan error, 1)

	if err := c.Start(); err != nil {
		return nil, nil, fmt.Errorf("start: %w", err)
	}

	go func() {
		defer close(lines)
		defer close(errs)

		var wg sync.WaitGroup
		emit := func(s *bufio.Scanner, prefix string) {
			defer wg.Done()
			for s.Scan() {
				select {
				case <-ctx.Done():
					errs <- ctx.Err()
					return
				case lines <- prefix + s.Text():
				}
			}
			if err := s.Err(); err != nil {
				errs <- err
			}
		}

		wg.Add(2)
		go emit(bufio.NewScanner(stdout), "")
		go emit(bufio.NewScanner(stderr), "[stderr] ")
		wg.Wait()

		if err := c.Wait(); err != nil {
			var ex *exec.ExitError
			if !errors.As(err, &ex) {
				errs <- err
			}
		}
	}()

	return lines, errs, nil
}

func (e *LocalExecutor) ReadFile(_ context.Context, path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (e *LocalExecutor) WriteFile(_ context.Context, path string, data []byte) error {
	return os.WriteFile(path, data, 0o644)
}
