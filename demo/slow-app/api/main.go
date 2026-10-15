package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
)

func main() {
	ctx := context.Background()
	redisAddr := envOr("REDIS_ADDR", "localhost:6379")
	postgresDSN := envOr("POSTGRES_DSN", "postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable")

	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	db, err := sql.Open("postgres", postgresDSN)
	if err != nil {
		log.Fatal(err)
	}

	h := http.NewServeMux()
	h.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		if err := rdb.Ping(ctx).Err(); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		if err := db.Ping(); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ok"))
	})

	h.HandleFunc("/work", func(w http.ResponseWriter, _ *http.Request) {
		start := time.Now()
		var one int
		if err := db.QueryRow("select 1").Scan(&one); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// Intentional bug: O(N) scan via KEYS on every request.
		keys, err := rdb.Keys(ctx, "*").Result()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if len(keys) > 0 {
			_, _ = rdb.Get(ctx, keys[len(keys)-1]).Result()
		}

		_, _ = fmt.Fprintf(w, "ok keys=%d latency_ms=%d", len(keys), time.Since(start).Milliseconds())
	})

	h.HandleFunc("/seed", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		if n <= 0 {
			n = 1000
		}
		for i := 0; i < n; i++ {
			_ = rdb.Set(ctx, fmt.Sprintf("k:%06d", i), strings.Repeat("x", 64), 0).Err()
		}
		_, _ = fmt.Fprintf(w, "seeded=%d", n)
	})

	log.Println("api listening on :8081")
	log.Fatal(http.ListenAndServe(":8081", h))
}

func envOr(k, fallback string) string {
	v := os.Getenv(k)
	if v == "" {
		return fallback
	}
	return v
}
