package linux

import (
	"bufio"
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/kai-ai/kai/pkg/models"
)

type collector struct {
	seen map[int]struct{}
}

func New() *collector { return &collector{seen: map[int]struct{}{}} }

func (c *collector) Start(ctx context.Context, out chan<- models.RawEvent) error {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			c.scan(out)
		}
	}
}

func (c *collector) scan(out chan<- models.RawEvent) {
	cmd := exec.Command("ps", "-axo", "pid=,ppid=,comm=,args=")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	s := bufio.NewScanner(stdout)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(fields[0])
		ppid, _ := strconv.Atoi(fields[1])
		proc := fields[2]
		args := strings.Join(fields[3:], " ")
		if _, ok := c.seen[pid]; ok {
			continue
		}
		c.seen[pid] = struct{}{}
		out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionProcSpawn, Target: args, Platform: "linux"}
		if args != "" {
			out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionExec, Target: args, Platform: "linux"}
		}
	}
	_ = cmd.Wait()
}
