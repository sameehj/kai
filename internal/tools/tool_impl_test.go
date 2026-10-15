package tools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kai-agent/kai/internal/channels"
	"github.com/kai-agent/kai/internal/executor"
	"github.com/kai-agent/kai/internal/llm"
)

type reportSink struct{ last channels.Message }

func (s *reportSink) Send(_ context.Context, msg channels.Message) error {
	s.last = msg
	return nil
}

func TestWriteReadAndAppendModes(t *testing.T) {
	r := NewRegistry()
	RegisterBuiltins(r)
	sink := &reportSink{}
	deps := Dependencies{Executor: executor.NewLocalExecutor(), Reporter: sink, Target: "local"}

	dir := t.TempDir()
	path := filepath.Join(dir, "a.txt")

	_, err := r.Execute(context.Background(), []llm.ToolCall{{Name: "write", Args: json.RawMessage(`{"path":"` + path + `","content":"hello","mode":"create"}`)}}, deps)
	if err != nil {
		t.Fatalf("write(create): %v", err)
	}
	res, err := r.Execute(context.Background(), []llm.ToolCall{{Name: "write", Args: json.RawMessage(`{"path":"` + path + `","content":" world","mode":"append"}`)}}, deps)
	if err != nil || !res[0].Success {
		t.Fatalf("write(append): %v %+v", err, res)
	}
	res, err = r.Execute(context.Background(), []llm.ToolCall{{Name: "read", Args: json.RawMessage(`{"path":"` + path + `"}`)}}, deps)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var out map[string]any
	_ = json.Unmarshal([]byte(res[0].Output), &out)
	if !strings.Contains(out["content"].(string), "hello world") {
		t.Fatalf("unexpected content: %+v", out)
	}
}

func TestSearchScopes(t *testing.T) {
	r := NewRegistry()
	RegisterBuiltins(r)
	deps := Dependencies{Executor: executor.NewLocalExecutor(), Reporter: &reportSink{}, Target: "local"}

	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "one.txt"), []byte("alpha"), 0o644); err != nil {
		t.Fatal(err)
	}
	cwd, _ := os.Getwd()
	defer os.Chdir(cwd)
	_ = os.Chdir(d)

	res, err := r.Execute(context.Background(), []llm.ToolCall{{Name: "search", Args: json.RawMessage(`{"query":"one","scope":"files"}`)}}, deps)
	if err != nil || !res[0].Success {
		t.Fatalf("search(files) failed: %v %+v", err, res)
	}
	res, err = r.Execute(context.Background(), []llm.ToolCall{{Name: "search", Args: json.RawMessage(`{"query":"alpha","scope":"content"}`)}}, deps)
	if err != nil || !res[0].Success {
		t.Fatalf("search(content) failed: %v %+v", err, res)
	}
}

func TestExecAndReport(t *testing.T) {
	r := NewRegistry()
	RegisterBuiltins(r)
	sink := &reportSink{}
	deps := Dependencies{Executor: executor.NewLocalExecutor(), Reporter: sink, Target: "local"}

	res, err := r.Execute(context.Background(), []llm.ToolCall{{Name: "exec", Args: json.RawMessage(`{"command":"echo ok"}`)}}, deps)
	if err != nil || !res[0].Success {
		t.Fatalf("exec failed: %v %+v", err, res)
	}
	res, err = r.Execute(context.Background(), []llm.ToolCall{{Name: "report", Args: json.RawMessage(`{"channel":"stdout","title":"t","body":"b"}`)}}, deps)
	if err != nil || !res[0].Success {
		t.Fatalf("report failed: %v %+v", err, res)
	}
	if sink.last.Title != "t" {
		t.Fatalf("expected report sink to receive title")
	}
}
