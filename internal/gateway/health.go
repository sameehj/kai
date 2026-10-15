package gateway

import (
	"encoding/json"
	"net/http"
	"time"
)

func healthHandler(started time.Time) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":         "ok",
			"uptime_seconds": int(time.Since(started).Seconds()),
			"version":        "0.1.0",
		})
	}
}
