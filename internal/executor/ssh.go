package executor

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type SSHConfig struct {
	Host                  string
	User                  string
	Port                  int
	PrivateKeyPath        string
	Password              string
	KnownHostsPath        string
	InsecureIgnoreHostKey bool
}

type SSHExecutor struct {
	cfg SSHConfig
}

func (e *SSHExecutor) Kind() string { return "ssh" }

func NewSSHExecutor(cfg SSHConfig) (*SSHExecutor, error) {
	if cfg.Host == "" {
		return nil, errors.New("host required")
	}
	if cfg.Port == 0 {
		cfg.Port = 22
	}
	if cfg.User == "" {
		if cur, err := user.Current(); err == nil {
			cfg.User = cur.Username
		}
	}
	if cfg.User == "" {
		return nil, errors.New("ssh user required")
	}
	if cfg.KnownHostsPath == "" && !cfg.InsecureIgnoreHostKey {
		home, err := os.UserHomeDir()
		if err == nil {
			cfg.KnownHostsPath = filepath.Join(home, ".ssh", "known_hosts")
		}
	}
	return &SSHExecutor{cfg: cfg}, nil
}

func (e *SSHExecutor) Run(ctx context.Context, cmd []string) (Result, error) {
	return e.RunWithOpts(ctx, cmd, RunOpts{})
}

func (e *SSHExecutor) RunWithOpts(ctx context.Context, cmd []string, opts RunOpts) (Result, error) {
	if len(cmd) == 0 {
		return Result{}, errors.New("empty command")
	}
	if opts.TimeoutSeconds > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(opts.TimeoutSeconds)*time.Second)
		defer cancel()
	}
	start := time.Now()

	command := shellJoin(cmd)
	if len(opts.Env) > 0 {
		var exports []string
		for k, v := range opts.Env {
			exports = append(exports, k+"="+shellQuote(v))
		}
		command = "env " + strings.Join(exports, " ") + " " + command
	}
	sshCmd := exec.CommandContext(ctx, "ssh", e.sshArgs(command)...)
	var stdout, stderr bytes.Buffer
	sshCmd.Stdout = &stdout
	sshCmd.Stderr = &stderr

	err := sshCmd.Run()
	out := stdout.String()
	errText := stderr.String()
	maxOut := opts.MaxOutputBytes
	if maxOut <= 0 {
		maxOut = 512 * 1024
	}
	if len(out) > maxOut {
		out = out[:maxOut]
	}
	if len(errText) > maxOut {
		errText = errText[:maxOut]
	}
	res := Result{Stdout: out, Stderr: errText, ExitCode: 0, DurationMS: time.Since(start).Milliseconds()}
	if err == nil {
		return res, nil
	}

	var ex *exec.ExitError
	if errors.As(err, &ex) {
		res.ExitCode = ex.ExitCode()
		return res, nil
	}
	return Result{}, err
}

func (e *SSHExecutor) Stream(ctx context.Context, cmd []string) (<-chan string, <-chan error, error) {
	if len(cmd) == 0 {
		return nil, nil, errors.New("empty command")
	}

	sshCmd := exec.CommandContext(ctx, "ssh", e.sshArgs(shellJoin(cmd))...)
	stdout, err := sshCmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	stderr, err := sshCmd.StderrPipe()
	if err != nil {
		return nil, nil, err
	}

	lines := make(chan string)
	errs := make(chan error, 1)
	if err := sshCmd.Start(); err != nil {
		return nil, nil, err
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

		if err := sshCmd.Wait(); err != nil {
			var ex *exec.ExitError
			if !errors.As(err, &ex) {
				errs <- err
			}
		}
	}()

	return lines, errs, nil
}

func (e *SSHExecutor) ReadFile(ctx context.Context, path string) ([]byte, error) {
	res, err := e.Run(ctx, []string{"cat", "--", path})
	if err != nil {
		return nil, err
	}
	if res.ExitCode != 0 {
		return nil, fmt.Errorf("cat failed (%d): %s", res.ExitCode, res.Stderr)
	}
	return []byte(res.Stdout), nil
}

func (e *SSHExecutor) WriteFile(ctx context.Context, path string, data []byte) error {
	sshCmd := exec.CommandContext(ctx, "ssh", e.sshArgs("cat > "+shellQuote(path))...)
	sshCmd.Stdin = bytes.NewReader(data)
	var stderr bytes.Buffer
	sshCmd.Stderr = &stderr
	if err := sshCmd.Run(); err != nil {
		var ex *exec.ExitError
		if errors.As(err, &ex) {
			return fmt.Errorf("remote write failed (%d): %s", ex.ExitCode(), stderr.String())
		}
		return err
	}
	return nil
}

func (e *SSHExecutor) sshArgs(remoteCommand string) []string {
	args := []string{
		"-p", strconv.Itoa(e.cfg.Port),
		"-o", "BatchMode=yes",
	}

	if e.cfg.InsecureIgnoreHostKey {
		args = append(args,
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
		)
	} else if e.cfg.KnownHostsPath != "" {
		args = append(args, "-o", "UserKnownHostsFile="+e.cfg.KnownHostsPath)
	}

	if e.cfg.PrivateKeyPath != "" {
		args = append(args, "-i", e.cfg.PrivateKeyPath)
	}

	target := e.cfg.Host
	if e.cfg.User != "" {
		target = e.cfg.User + "@" + e.cfg.Host
	}
	args = append(args, target, remoteCommand)
	return args
}

func shellJoin(args []string) string {
	q := make([]string, 0, len(args))
	for _, a := range args {
		q = append(q, shellQuote(a))
	}
	return strings.Join(q, " ")
}

func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
