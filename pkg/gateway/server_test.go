package gateway

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHandleHealth(t *testing.T) {
	s := &Server{started: timeNowMinus(2)}
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()

	s.handleHealth(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	var payload map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if payload["status"] != "ok" {
		t.Fatalf("expected status ok, got %v", payload["status"])
	}
}

func timeNowMinus(seconds int) time.Time {
	return time.Now().Add(-time.Duration(seconds) * time.Second)
}
