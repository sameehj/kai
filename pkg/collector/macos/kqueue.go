package macos

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/kai-ai/kai/pkg/models"
)

type collector struct {
	mu       sync.Mutex
	seenProc map[int]struct{}
	seenConn map[string]time.Time
	watched  map[int]struct{}
	kq       int
}

func New() *collector {
	return &collector{
		seenProc: map[int]struct{}{},
		seenConn: map[string]time.Time{},
		watched:  map[int]struct{}{},
		kq:       -1,
	}
}

func (c *collector) Start(ctx context.Context, out chan<- models.RawEvent) error {
	watcher, err := fsnotify.NewWatcher()
	if err == nil {
		defer watcher.Close()
		if cwd, e := os.Getwd(); e == nil {
			_ = addRecursive(watcher, cwd)
		}
		go c.consumeFS(ctx, watcher, out)
	}

	kqErr := c.startKqueue(ctx, out)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if c.kq >= 0 {
				_ = syscall.Close(c.kq)
			}
			return nil
		case <-ticker.C:
			c.scanProc(out)
			c.scanNet(out)
			if kqErr == nil {
				c.bootstrapKqueue()
			}
		}
	}
}

func (c *collector) startKqueue(ctx context.Context, out chan<- models.RawEvent) error {
	kq, err := syscall.Kqueue()
	if err != nil {
		return err
	}
	c.kq = kq
	c.bootstrapKqueue()
	go c.runKqueue(ctx, out)
	return nil
}

func (c *collector) bootstrapKqueue() {
	procs := listProcesses()
	for _, p := range procs {
		c.registerPID(p.pid)
	}
}

func (c *collector) runKqueue(ctx context.Context, out chan<- models.RawEvent) {
	events := make([]syscall.Kevent_t, 128)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		ts := syscall.Timespec{Sec: 1}
		n, err := syscall.Kevent(c.kq, nil, events, &ts)
		if err != nil {
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			return
		}
		for i := 0; i < n; i++ {
			ev := events[i]
			pid := int(ev.Ident)
			if ev.Fflags&syscall.NOTE_FORK != 0 {
				child := int(ev.Data)
				if child > 0 {
					c.registerPID(child)
					proc, args := procInfo(child)
					out <- models.RawEvent{Timestamp: time.Now(), PID: child, PPID: pid, ProcessName: proc, ActionType: models.ActionProcSpawn, Target: args, Platform: "macos"}
				}
			}
			if ev.Fflags&syscall.NOTE_EXEC != 0 {
				proc, args := procInfo(pid)
				out <- models.RawEvent{Timestamp: time.Now(), PID: pid, ProcessName: proc, ActionType: models.ActionExec, Target: args, Platform: "macos"}
				c.registerPID(pid)
			}
			if ev.Fflags&syscall.NOTE_EXIT != 0 {
				c.mu.Lock()
				delete(c.watched, pid)
				c.mu.Unlock()
			}
		}
	}
}

func (c *collector) registerPID(pid int) {
	if pid <= 0 || c.kq < 0 {
		return
	}
	c.mu.Lock()
	if _, ok := c.watched[pid]; ok {
		c.mu.Unlock()
		return
	}
	c.watched[pid] = struct{}{}
	c.mu.Unlock()

	kev := syscall.Kevent_t{
		Ident:  uint64(pid),
		Filter: syscall.EVFILT_PROC,
		Flags:  syscall.EV_ADD | syscall.EV_ENABLE | syscall.EV_ONESHOT,
		Fflags: syscall.NOTE_EXEC | syscall.NOTE_FORK | syscall.NOTE_EXIT,
	}
	_, _ = syscall.Kevent(c.kq, []syscall.Kevent_t{kev}, nil, nil)
}

func listProcesses() []procEntry {
	cmd := exec.Command("ps", "-axo", "pid=,comm=,args=")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil
	}
	if err := cmd.Start(); err != nil {
		return nil
	}
	defer cmd.Wait()
	entries := make([]procEntry, 0, 64)
	s := bufio.NewScanner(stdout)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		entries = append(entries, procEntry{pid: pid})
	}
	return entries
}

type procEntry struct{ pid int }

func procInfo(pid int) (string, string) {
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "comm=,args=")
	b, err := cmd.Output()
	if err != nil {
		return "", ""
	}
	line := strings.TrimSpace(string(b))
	f := strings.Fields(line)
	if len(f) == 0 {
		return "", ""
	}
	proc := f[0]
	args := ""
	if len(f) > 1 {
		args = strings.Join(f[1:], " ")
	}
	return proc, args
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

func (c *collector) scanProc(out chan<- models.RawEvent) {
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
		if _, ok := c.seenProc[pid]; ok {
			continue
		}
		c.seenProc[pid] = struct{}{}
		out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionProcSpawn, Target: args, Platform: "macos"}
		if args != "" {
			out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionExec, Target: args, Platform: "macos"}
		}
	}
	_ = cmd.Wait()
}

func (c *collector) scanNet(out chan<- models.RawEvent) {
	cmd := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	defer cmd.Wait()

	var (
		pid  int
		proc string
	)
	s := bufio.NewScanner(stdout)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			pid, _ = strconv.Atoi(line[1:])
		case 'c':
			proc = line[1:]
		case 'n':
			remote := parseRemoteFromLsof(line[1:])
			if remote == "" {
				continue
			}
			key := strconv.Itoa(pid) + "|" + remote
			if _, ok := c.seenConn[key]; ok {
				continue
			}
			c.seenConn[key] = time.Now()
			out <- models.RawEvent{
				Timestamp:   time.Now(),
				PID:         pid,
				ProcessName: proc,
				ActionType:  models.ActionNetConnect,
				Target:      remote,
				Platform:    "macos",
			}
		}
	}
	c.gcConnCache()
}

func parseRemoteFromLsof(name string) string {
	parts := strings.Split(name, "->")
	if len(parts) != 2 {
		return ""
	}
	right := strings.TrimSpace(parts[1])
	if idx := strings.Index(right, " "); idx >= 0 {
		right = right[:idx]
	}
	if idx := strings.Index(right, "("); idx >= 0 {
		right = strings.TrimSpace(right[:idx])
	}
	if right == "" || !strings.Contains(right, ":") {
		return ""
	}
	return right
}

func (c *collector) gcConnCache() {
	cut := time.Now().Add(-2 * time.Minute)
	for k, t := range c.seenConn {
		if t.Before(cut) {
			delete(c.seenConn, k)
		}
	}
}
