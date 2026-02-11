package toolwatcher

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/sameehj/kai/pkg/tool"
	"log/slog"
)

const debounceDelay = 300 * time.Millisecond

type Watcher struct {
	registry *tool.Registry
	path     string
	watcher  *fsnotify.Watcher
	mu       sync.Mutex
	debounce map[string]*time.Timer
	logger   *slog.Logger
}

func New(registry *tool.Registry, path string) *Watcher {
	return &Watcher{registry: registry, path: path, debounce: make(map[string]*time.Timer)}
}

func (w *Watcher) SetLogger(logger *slog.Logger) {
	w.logger = logger
}

func (w *Watcher) Start(ctx context.Context) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	w.watcher = watcher
	if err := w.addRecursive(w.path); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			_ = w.watcher.Close()
			return ctx.Err()
		case event, ok := <-w.watcher.Events:
			if !ok {
				return nil
			}
			if event.Has(fsnotify.Create) {
				if info, err := os.Stat(event.Name); err == nil && info.IsDir() {
					_ = w.addRecursive(event.Name)
				}
			}
			if shouldReload(event) {
				w.scheduleReload(event.Name)
			}
		case err, ok := <-w.watcher.Errors:
			if !ok {
				return nil
			}
			w.logError("watcher_error", "error", err)
		}
	}
}

func (w *Watcher) addRecursive(root string) error {
	if _, err := os.Stat(root); err != nil {
		return err
	}
	return filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return w.watcher.Add(path)
		}
		return nil
	})
}

func shouldReload(event fsnotify.Event) bool {
	if event.Has(fsnotify.Write) || event.Has(fsnotify.Create) || event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) {
		return true
	}
	return false
}

func (w *Watcher) scheduleReload(path string) {
	toolPath := resolveToolPath(path)
	if toolPath == "" {
		return
	}

	w.mu.Lock()
	if timer, ok := w.debounce[toolPath]; ok {
		timer.Stop()
	}
	w.debounce[toolPath] = time.AfterFunc(debounceDelay, func() {
		w.mu.Lock()
		delete(w.debounce, toolPath)
		w.mu.Unlock()

		if err := w.registry.ReloadTool(toolPath); err != nil {
			w.logError("tool_reload_failed", "path", toolPath, "error", err)
			return
		}
		w.logInfo("tool_reloaded", "path", toolPath)
	})
	w.mu.Unlock()
}

func resolveToolPath(path string) string {
	info, err := os.Stat(path)
	if err == nil && info.IsDir() {
		return path
	}
	base := filepath.Base(path)
	if strings.EqualFold(base, "TOOL.md") {
		return filepath.Dir(path)
	}
	return ""
}

func (w *Watcher) logInfo(msg string, args ...any) {
	if w.logger != nil {
		w.logger.Info(msg, args...)
	}
}

func (w *Watcher) logError(msg string, args ...any) {
	if w.logger != nil {
		w.logger.Error(msg, args...)
	}
}
