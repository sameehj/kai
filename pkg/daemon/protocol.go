package daemon

import (
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
)

type RPCRequest struct {
	Action      string          `json:"action"`
	Agent       *models.AgentID `json:"agent,omitempty"`
	MinRisk     int             `json:"min_risk,omitempty"`
	Limit       int             `json:"limit,omitempty"`
	SessionID   string          `json:"session_id,omitempty"`
	UnknownOnly bool            `json:"unknown_only,omitempty"`
}

type ReportRow struct {
	Agent    string `json:"agent"`
	Sessions int    `json:"sessions"`
	FileOps  int    `json:"file_ops"`
	Execs    int    `json:"execs"`
	MaxRisk  int    `json:"max_risk"`
}

type RPCStatus struct {
	Running bool          `json:"running"`
	PID     int           `json:"pid"`
	Uptime  time.Duration `json:"uptime"`
	Events  int64         `json:"events"`
}

type RPCResponse struct {
	OK       bool                  `json:"ok"`
	Error    string                `json:"error,omitempty"`
	Status   *RPCStatus            `json:"status,omitempty"`
	Sessions []models.Session      `json:"sessions,omitempty"`
	Replay   *storage.ReplayResult `json:"replay,omitempty"`
	Report   []ReportRow           `json:"report,omitempty"`
	Event    *models.AgentEvent    `json:"event,omitempty"`
	RawEvent *models.RawEvent      `json:"raw_event,omitempty"`
}
