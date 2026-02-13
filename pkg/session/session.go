package session

import (
	"strings"
	"time"
)

type SessionID string

type SessionType string

const (
	MainSession SessionID = "agent:main:main"

	TypeMain  SessionType = "main"
	TypeDM    SessionType = "dm"
	TypeGroup SessionType = "group"
)

type Session struct {
	ID        SessionID
	Type      SessionType
	Channel   string
	Messages  []Message
	CreatedAt time.Time
	UpdatedAt time.Time
}

type Message struct {
	Role      string     `json:"role"`
	Content   string     `json:"content"`
	Timestamp time.Time  `json:"timestamp"`
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`
}

type ToolCall struct {
	Name   string                 `json:"name"`
	Input  map[string]interface{} `json:"input"`
	Result string                 `json:"result"`
}

func Parse(id SessionID) (SessionType, string, string) {
	parts := strings.Split(string(id), ":")
	if len(parts) < 3 {
		return TypeMain, "", ""
	}
	typ := SessionType(parts[2])
	if len(parts) >= 5 {
		return typ, parts[3], parts[4]
	}
	return typ, "", ""
}
