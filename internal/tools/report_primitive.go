package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/kai-agent/kai/internal/channels"
)

type reportTool struct{}

type reportArgs struct {
	Channel     string   `json:"channel,omitempty"`
	Title       string   `json:"title"`
	Body        string   `json:"body"`
	Severity    string   `json:"severity,omitempty"`
	Attachments []string `json:"attachments,omitempty"`
}

func (reportTool) Definition() Definition {
	return Definition{Name: "report", Description: "Send a formatted report to channel", InputSchema: objSchema(req("title", strSchema("title")), req("body", strSchema("markdown body")), opt("channel", strSchema("channel route")), opt("severity", strSchema("info|warning|critical")))}
}

func (reportTool) Invoke(ctx context.Context, call Call, deps Dependencies) (Result, error) {
	var a reportArgs
	if err := decodeArgs(call.Args, &a); err != nil {
		return Result{}, err
	}
	if deps.Reporter == nil {
		return Result{}, fmt.Errorf("no report dispatcher configured")
	}
	if a.Channel == "" {
		a.Channel = "stdout"
	}
	if a.Severity == "" {
		a.Severity = "info"
	}
	start := time.Now()
	err := deps.Reporter.Send(ctx, channels.Message{Channel: a.Channel, Title: a.Title, Body: a.Body, Severity: a.Severity, Attachments: a.Attachments})
	dur := time.Since(start).Milliseconds()
	if err != nil {
		_ = logEvidence(deps, "report", map[string]any{"channel": a.Channel, "title": a.Title, "severity": a.Severity}, nil, dur, err, "allow")
		return Result{}, err
	}
	payload := map[string]any{"channel": a.Channel, "title": a.Title, "severity": a.Severity}
	b, _ := json.Marshal(payload)
	_ = logEvidence(deps, "report", map[string]any{"channel": a.Channel, "title": a.Title, "severity": a.Severity}, payload, dur, nil, "allow")
	return Result{Tool: "report", Success: true, Output: string(b)}, nil
}
