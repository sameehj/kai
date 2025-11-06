package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return fn(req)
}

func TestCallMCPTool(t *testing.T) {
	t.Parallel()

	httpClientFactory = func() *http.Client {
		return &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				var payload map[string]interface{}
				if err := json.NewDecoder(req.Body).Decode(&payload); err != nil {
					t.Fatalf("unexpected decode error: %v", err)
				}
				body, _ := json.Marshal(map[string]interface{}{
					"result": map[string]string{"status": "ok"},
				})
				resp := &http.Response{
					StatusCode: http.StatusOK,
					Body:       io.NopCloser(bytes.NewReader(body)),
					Header:     make(http.Header),
				}
				return resp, nil
			}),
		}
	}
	defer func() { httpClientFactory = func() *http.Client { return &http.Client{Timeout: 5 * time.Second} } }()

	result, err := callMCPTool("http://local", "kai__inspect_state", map[string]string{})
	if err != nil {
		t.Fatalf("callMCPTool returned error: %v", err)
	}

	var payload map[string]string
	if err := json.Unmarshal(result, &payload); err != nil {
		t.Fatalf("unexpected response payload: %v", err)
	}
	if payload["status"] != "ok" {
		t.Fatalf("expected status ok, got %q", payload["status"])
	}
}
