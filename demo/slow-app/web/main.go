package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	apiURL := os.Getenv("API_URL")
	if apiURL == "" {
		apiURL = "http://localhost:8081"
	}

	h := http.NewServeMux()
	h.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	h.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		start := time.Now()
		resp, err := http.Get(apiURL + "/work")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		_, _ = fmt.Fprintf(w, "web latency_ms=%d api_status=%d body=%s\n", time.Since(start).Milliseconds(), resp.StatusCode, string(body))
	})

	log.Println("web listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", h))
}
