package linux

import (
	"bufio"
	"context"
	"encoding/hex"
	"net"
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
	seenProc map[int]struct{}
	seenConn map[string]time.Time
}

func New() *collector {
	return &collector{seenProc: map[int]struct{}{}, seenConn: map[string]time.Time{}}
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

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			c.scanProc(out)
			c.scanNet(out)
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
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileCreate, Target: ev.Name, Platform: "linux"}
			}
			if ev.Op&fsnotify.Write == fsnotify.Write {
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileWrite, Target: ev.Name, Platform: "linux"}
			}
			if ev.Op&fsnotify.Remove == fsnotify.Remove || ev.Op&fsnotify.Rename == fsnotify.Rename {
				out <- models.RawEvent{Timestamp: time.Now(), ActionType: models.ActionFileDelete, Target: ev.Name, Platform: "linux"}
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
		out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionProcSpawn, Target: args, Platform: "linux"}
		if args != "" {
			out <- models.RawEvent{Timestamp: time.Now(), PID: pid, PPID: ppid, ProcessName: proc, ActionType: models.ActionExec, Target: args, Platform: "linux"}
		}
	}
	_ = cmd.Wait()
}

func (c *collector) scanNet(out chan<- models.RawEvent) {
	inodePID := c.buildInodePIDMap()
	c.scanProcNetFile("/proc/net/tcp", inodePID, out)
	c.scanProcNetFile("/proc/net/tcp6", inodePID, out)
	c.gcConnCache()
}

func (c *collector) scanProcNetFile(path string, inodePID map[string]int, out chan<- models.RawEvent) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	first := true
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		if first {
			first = false
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}
		state := fields[3]
		if state != "01" { // ESTABLISHED
			continue
		}
		remoteIP, remotePort, ok := parseHexAddr(fields[2])
		if !ok || remoteIP == "0.0.0.0" || remoteIP == "::" {
			continue
		}
		inode := fields[9]
		key := inode + "|" + remoteIP + ":" + strconv.Itoa(remotePort)
		if _, seen := c.seenConn[key]; seen {
			continue
		}
		c.seenConn[key] = time.Now()
		pid := inodePID[inode]
		procName := processName(pid)
		out <- models.RawEvent{
			Timestamp:   time.Now(),
			PID:         pid,
			ProcessName: procName,
			ActionType:  models.ActionNetConnect,
			Target:      remoteIP + ":" + strconv.Itoa(remotePort),
			Platform:    "linux",
		}
	}
}

func (c *collector) buildInodePIDMap() map[string]int {
	res := map[string]int{}
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return res
	}
	for _, ent := range ents {
		pid, err := strconv.Atoi(ent.Name())
		if err != nil {
			continue
		}
		fdDir := filepath.Join("/proc", ent.Name(), "fd")
		fds, err := os.ReadDir(fdDir)
		if err != nil {
			continue
		}
		for _, fd := range fds {
			link, err := os.Readlink(filepath.Join(fdDir, fd.Name()))
			if err != nil {
				continue
			}
			if strings.HasPrefix(link, "socket:[") && strings.HasSuffix(link, "]") {
				inode := strings.TrimSuffix(strings.TrimPrefix(link, "socket:["), "]")
				if _, ok := res[inode]; !ok {
					res[inode] = pid
				}
			}
		}
	}
	return res
}

func processName(pid int) string {
	if pid <= 0 {
		return ""
	}
	b, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "comm"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func parseHexAddr(v string) (string, int, bool) {
	parts := strings.Split(v, ":")
	if len(parts) != 2 {
		return "", 0, false
	}
	port64, err := strconv.ParseUint(parts[1], 16, 16)
	if err != nil {
		return "", 0, false
	}
	addrHex := parts[0]
	b, err := hex.DecodeString(addrHex)
	if err != nil {
		return "", 0, false
	}
	if len(b) == 4 {
		for i := 0; i < 2; i++ {
			b[i], b[len(b)-1-i] = b[len(b)-1-i], b[i]
		}
		return net.IPv4(b[0], b[1], b[2], b[3]).String(), int(port64), true
	}
	if len(b) == 16 {
		for i := 0; i < 16; i += 4 {
			b[i], b[i+3] = b[i+3], b[i]
			b[i+1], b[i+2] = b[i+2], b[i+1]
		}
		return net.IP(b).String(), int(port64), true
	}
	return "", 0, false
}

func (c *collector) gcConnCache() {
	cut := time.Now().Add(-2 * time.Minute)
	for k, t := range c.seenConn {
		if t.Before(cut) {
			delete(c.seenConn, k)
		}
	}
}
