package evidence

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Logger struct {
	mu       sync.Mutex
	runID    string
	runDir   string
	f        *os.File
	w        *bufio.Writer
	closed   bool
	metadata map[string]any
}

type Event struct {
	Timestamp      time.Time      `json:"ts"`
	Tool           string         `json:"tool"`
	Target         string         `json:"target,omitempty"`
	Input          map[string]any `json:"input,omitempty"`
	Output         map[string]any `json:"output,omitempty"`
	DurationMS     int64          `json:"duration_ms,omitempty"`
	PolicyDecision string         `json:"policy_decision,omitempty"`
	Error          string         `json:"error,omitempty"`
}

func Start(baseDir, skill, target string) (*Logger, error) {
	if baseDir == "" {
		home, _ := os.UserHomeDir()
		baseDir = filepath.Join(home, ".kai", "runs")
	}
	_ = os.MkdirAll(baseDir, 0o755)
	ts := time.Now().UTC().Format("2006-01-02T15-04-05Z")
	runID := fmt.Sprintf("%s_%s_%s", ts, sanitize(skill), sanitize(target))
	runDir := filepath.Join(baseDir, runID)
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(runDir, "commands.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &Logger{runID: runID, runDir: runDir, f: f, w: bufio.NewWriter(f), metadata: map[string]any{"skill": skill, "target": target}}, nil
}

func (l *Logger) RunID() string { return l.runID }
func (l *Logger) RunDir() string { return l.runDir }

func (l *Logger) Log(e Event) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	if e.Timestamp.IsZero() {
		e.Timestamp = time.Now().UTC()
	}
	b, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if _, err := l.w.Write(append(b, '\n')); err != nil {
		return err
	}
	return l.w.Flush()
}

func (l *Logger) Finalize(summary string, findings map[string]any) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	if summary != "" {
		_ = os.WriteFile(filepath.Join(l.runDir, "summary.md"), []byte(summary+"\n"), 0o644)
	}
	if findings != nil {
		if b, err := json.MarshalIndent(findings, "", "  "); err == nil {
			_ = os.WriteFile(filepath.Join(l.runDir, "findings.json"), b, 0o644)
		}
	}
	l.closed = true
	_ = l.w.Flush()
	return l.f.Close()
}

func sanitize(s string) string {
	if s == "" {
		return "unknown"
	}
	out := make([]rune, 0, len(s))
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			out = append(out, r)
		case r == '-', r == '_':
			out = append(out, r)
		default:
			out = append(out, '_')
		}
	}
	return string(out)
}
