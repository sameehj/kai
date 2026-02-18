package macos

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/kai-ai/kai/pkg/models"
)

type collector struct {
	seen map[int]struct{}
}

func New() *collector { return &collector{seen: map[int]struct{}{}} }

func (c *collector) Start(ctx context.Context, out chan<- models.RawEvent) error {
	watcher, err := fsnotify.NewWatcher()
	if err == nil {
		defer watcher.Close()
		if cwd, e := os.Getwd(); e == nil {
			_ = addRecursive(watcher, cwd)
		}
		go c.consumeFS(ctx, watcher, out)
	}

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

func (c *collector) consumeFS(ctx context.Context, watcher *fsnotify.Watcher, out chan<- models.RawEvent) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-watcher.Events:
			if ev.Name == "" {
				continue
			}
			if ev.Op&fsnotify.Create == fsnotify.Create {
				if st, err := os.Stat(ev.Name); err == nil && st.IsDir() {
					_ = addRecursive(watcher, ev.Name)
				}
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileCreate, Target: ev.Name, Platform: "macos"}
			}
			if ev.Op&fsnotify.Write == fsnotify.Write {
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileWrite, Target: ev.Name, Platform: "macos"}
			}
			if ev.Op&fsnotify.Remove == fsnotify.Remove || ev.Op&fsnotify.Rename == fsnotify.Rename {
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileDelete, Target: ev.Name, Platform: "macos"}
			}
		case <-watcher.Errors:
		}
	}
}

func addRecursive(w *fsnotify.Watcher, root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		name := d.Name()
		if name == ".git" || name == ".cache" || name == "node_modules" {
			return filepath.SkipDir
		}
		_ = w.Add(path)
		return nil
	})
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
		out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionProcSpawn, Target: args, Platform: "macos"}
		if args != "" {
			out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionExec, Target: args, Platform: "macos"}
		}
	}
	_ = cmd.Wait()
}
