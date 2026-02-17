package models

import "time"

type AgentID string

const (
	AgentCursor   AgentID = "cursor"
	AgentClaude   AgentID = "claude"
	AgentCodex    AgentID = "codex"
	AgentCopilot  AgentID = "copilot"
	AgentOllama   AgentID = "ollama"
	AgentLMStudio AgentID = "lmstudio"
	AgentGemini   AgentID = "gemini"
	AgentUnknown  AgentID = "unknown"
)

type ActionType string

const (
	ActionExec       ActionType = "EXEC"
	ActionFileWrite  ActionType = "FILE_WRITE"
	ActionFileCreate ActionType = "FILE_CREATE"
	ActionFileDelete ActionType = "FILE_DELETE"
	ActionNetConnect ActionType = "NET_CONNECT"
	ActionProcSpawn  ActionType = "PROC_SPAWN"
)

type FileChangeType string

const (
	FileCreated  FileChangeType = "CREATED"
	FileModified FileChangeType = "MODIFIED"
	FileDeleted  FileChangeType = "DELETED"
)

type Session struct {
	ID           string
	Agent        AgentID
	StartedAt    time.Time
	EndedAt      *time.Time
	Duration     time.Duration
	LastActivity time.Time
	CWDs         []string
	RepoRoot     *string
	RepoBranch   *string

	FileWrites    int
	FileCreates   int
	FileDeletes   int
	ExecCount     int
	NetCount      int
	MaxRisk       int
	TopRiskLabels []string
}

// RawEvent is used only in the in-memory collection pipeline.
type RawEvent struct {
	Timestamp   time.Time
	PID         int
	PPID        int
	ProcessName string
	ActionType  ActionType
	Target      string
	ExecArgs    []string
	Platform    string
}

// AgentEvent is a classified event emitted by the attribution engine.
type AgentEvent struct {
	ID          string
	Timestamp   time.Time
	Agent       AgentID
	SessionID   string
	ActionType  ActionType
	Target      string
	ExecArgs    []string
	RiskScore   int
	RiskLabels  []string
	PID         int
	ProcessName string
	Platform    string
}

type ExecEvent struct {
	ID         string
	SessionID  string
	Timestamp  time.Time
	Command    string
	Args       []string
	CWD        string
	RiskScore  int
	RiskLabels []string
}

type NetEvent struct {
	ID           string
	SessionID    string
	Timestamp    time.Time
	RemoteIP     string
	RemotePort   int
	Domain       *string
	Protocol     string
	BytesSent    int64
	BytesRecv    int64
	IsAIEndpoint bool
	RiskScore    int
}

// SessionFile is one aggregated row per (session_id, file_path).
type SessionFile struct {
	ID           string
	SessionID    string
	FilePath     string
	ChangeType   FileChangeType
	LinesAdded   int
	LinesRemoved int
	SaveCount    int
	FirstSeen    time.Time
	LastSeen     time.Time
	SnapshotID   *string
	IsRedacted   bool
}

type Snapshot struct {
	ID            string
	SessionFileID string
	CapturedAt    time.Time
	BeforeText    *[]byte
	AfterText     *[]byte
	BeforeHash    *string
	AfterHash     *string
	LinesAdded    int
	LinesRemoved  int
	Compressed    bool
}
