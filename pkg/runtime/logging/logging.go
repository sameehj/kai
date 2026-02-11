package logging

import (
	"log/slog"
	"os"
	"strings"
)

// New returns a structured logger. format can be "json" or "text".
func New(level, format string) *slog.Logger {
	lvl := parseLevel(level)
	if strings.EqualFold(format, "text") {
		return slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
}

func parseLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
