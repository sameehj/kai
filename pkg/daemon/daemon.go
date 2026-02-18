package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/kai-ai/kai/pkg/attribution"
	"github.com/kai-ai/kai/pkg/collector"
	"github.com/kai-ai/kai/pkg/config"
	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/snapshot"
	"github.com/kai-ai/kai/pkg/storage"
)

type Status struct {
	Running bool
	PID     int
	Uptime  time.Duration
	Events  int64
}

type Daemon struct {
	cfg       config.Config
	store     *storage.DB
	collector collector.Collector
	engine    *attribution.Engine
	snap      *snapshot.Manager

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	events int64
	start  time.Time
}

func New(cfg config.Config) (*Daemon, error) {
	st, err := storage.Open(cfg.Daemon.DBPath)
	if err != nil {
		return nil, err
	}
	_ = st.PurgeOlderThan(time.Duration(cfg.Daemon.RetentionDays) * 24 * time.Hour)
	snapCfg := snapshot.Config{SnapshotEnabled: cfg.Snapshot.Enabled, MaxSnapshotSizeBytes: cfg.Snapshot.MaxFileKB * 1024, SkipExtensions: map[string]struct{}{}, ExtraSkipPaths: cfg.Privacy.ExtraSkipPaths}
	for _, ext := range cfg.Snapshot.SkipExtensions {
		snapCfg.SkipExtensions[ext] = struct{}{}
	}

	ctx, cancel := context.WithCancel(context.Background())
	return &Daemon{
		cfg: cfg, store: st, collector: collector.NewCollector(),
		engine: attribution.NewEngine(st), snap: snapshot.NewManager(st, snapCfg),
		ctx: ctx, cancel: cancel,
	}, nil
}

func (d *Daemon) Start() error {
	d.start = time.Now()
	if err := os.MkdirAll(filepath.Dir(d.cfg.Daemon.SocketPath), 0o700); err != nil {
		return err
	}
	_ = os.Remove(d.cfg.Daemon.SocketPath)

	rawEvents := make(chan models.RawEvent, 2048)
	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		_ = d.collector.Start(d.ctx, rawEvents)
	}()

	d.wg.Add(1)
	go func() {
		defer d.wg.Done()
		for {
			select {
			case <-d.ctx.Done():
				return
			case ev := <-rawEvents:
				agentEv := d.engine.Process(ev)
				if agentEv == nil {
					continue
				}
				switch agentEv.ActionType {
				case models.ActionFileCreate:
					d.snap.OnFileEvent(agentEv.SessionID, agentEv.Target, models.FileCreated)
				case models.ActionFileWrite:
					d.snap.OnFileEvent(agentEv.SessionID, agentEv.Target, models.FileModified)
				case models.ActionFileDelete:
					d.snap.OnFileDelete(agentEv.SessionID, agentEv.Target)
				}
			}
		}
	}()

	if err := d.writePID(); err != nil {
		return err
	}

	listener, err := net.Listen("unix", d.cfg.Daemon.SocketPath)
	if err != nil {
		return err
	}
	d.wg.Add(1)
	go d.serve(listener)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-d.ctx.Done():
	case <-sig:
	}
	_ = d.Stop()
	return nil
}

func (d *Daemon) serve(listener net.Listener) {
	defer d.wg.Done()
	defer listener.Close()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if d.ctx.Err() != nil {
				return
			}
			continue
		}
		d.wg.Add(1)
		go func(c net.Conn) {
			defer d.wg.Done()
			defer c.Close()
			enc := json.NewEncoder(c)
			ch := make(chan models.AgentEvent, 64)
			d.engine.Watch(ch)
			for {
				select {
				case <-d.ctx.Done():
					return
				case ev := <-ch:
					_ = enc.Encode(ev)
				}
			}
		}(conn)
	}
}

func (d *Daemon) Stop() error {
	d.cancel()
	d.snap.FlushAll()
	d.engine.Close()
	d.wg.Wait()
	_ = os.Remove(d.cfg.Daemon.SocketPath)
	_ = os.Remove(d.pidPath())
	return d.store.Close()
}

func (d *Daemon) writePID() error {
	return os.WriteFile(d.pidPath(), []byte(fmt.Sprintf("%d", os.Getpid())), 0o600)
}

func (d *Daemon) pidPath() string { return filepath.Join(filepath.Dir(d.cfg.Daemon.DBPath), "kai.pid") }

func RunningStatus(cfg config.Config) (Status, error) {
	b, err := os.ReadFile(filepath.Join(filepath.Dir(cfg.Daemon.DBPath), "kai.pid"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Status{}, nil
		}
		return Status{}, err
	}
	pid := 0
	for _, c := range b {
		if c >= '0' && c <= '9' {
			pid = pid*10 + int(c-'0')
		}
	}
	if pid <= 0 {
		return Status{}, nil
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return Status{}, nil
	}
	if err := proc.Signal(syscall.Signal(0)); err != nil {
		return Status{}, nil
	}
	return Status{Running: true, PID: pid}, nil
}
