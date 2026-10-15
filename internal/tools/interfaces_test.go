package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/kai-agent/kai/internal/llm"
)

type echoTool struct{}

func (echoTool) Definition() Definition {
	return Definition{Name: "echo", Description: "echo"}
}

func (echoTool) Invoke(_ context.Context, call Call, _ Dependencies) (Result, error) {
	var payload struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(call.Args, &payload)
	return Result{Success: true, Output: payload.Text}, nil
}

func TestRegistryDuplicateRegister(t *testing.T) {
	r := NewRegistry()
	if err := r.Register(echoTool{}); err != nil {
		t.Fatalf("register first: %v", err)
	}
	if err := r.Register(echoTool{}); err == nil {
		t.Fatal("expected duplicate register error")
	}
}

func TestRegistryExecute(t *testing.T) {
	r := NewRegistry()
	if err := r.Register(echoTool{}); err != nil {
		t.Fatalf("register: %v", err)
	}

	results, err := r.Execute(context.Background(), []llm.ToolCall{
		{Name: "echo", Args: json.RawMessage(`{"text":"ok"}`)},
		{Name: "missing", Args: json.RawMessage(`{}`)},
	}, Dependencies{})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}
	if !results[0].Success || results[0].Output != "ok" {
		t.Fatalf("unexpected first result: %+v", results[0])
	}
	if results[1].Success || results[1].Error == "" {
		t.Fatalf("unexpected second result: %+v", results[1])
	}
}
