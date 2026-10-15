package evidence

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func ListRuns(baseDir string) ([]string, error) {
	entries, err := os.ReadDir(baseDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	runs := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			runs = append(runs, e.Name())
		}
	}
	sort.Strings(runs)
	return runs, nil
}

func LastRun(baseDir string) (string, error) {
	runs, err := ListRuns(baseDir)
	if err != nil || len(runs) == 0 {
		return "", err
	}
	return runs[len(runs)-1], nil
}

func Replay(baseDir, runID string) (string, error) {
	if runID == "last" {
		last, err := LastRun(baseDir)
		if err != nil {
			return "", err
		}
		runID = last
	}
	fp := filepath.Join(baseDir, runID, "commands.jsonl")
	f, err := os.Open(fp)
	if err != nil {
		return "", err
	}
	defer f.Close()
	var out strings.Builder
	s := bufio.NewScanner(f)
	for s.Scan() {
		var ev Event
		if err := json.Unmarshal(s.Bytes(), &ev); err != nil {
			continue
		}
		fmt.Fprintf(&out, "%s %s target=%s duration=%dms\n", ev.Timestamp.Format("2006-01-02T15:04:05Z"), ev.Tool, ev.Target, ev.DurationMS)
	}
	if err := s.Err(); err != nil {
		return "", err
	}
	return out.String(), nil
}
