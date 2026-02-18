package attribution

import (
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
	"github.com/kai-ai/kai/pkg/utils"
)

const (
	SessionIdleTimeout = 30 * time.Second
	SessionMaxDuration = 4 * time.Hour
)

type SessionManager struct {
	mu     sync.Mutex
	active map[models.AgentID]*models.Session
	store  *storage.DB
}

func NewSessionManager(store *storage.DB) *SessionManager {
	return &SessionManager{store: store, active: map[models.AgentID]*models.Session{}}
}

func (sm *SessionManager) OnEvent(event *models.AgentEvent) *models.Session {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	now := event.Timestamp
	session, exists := sm.active[event.Agent]
	if !exists || sm.isExpired(session, now) {
		if exists {
			sm.closeSessionLocked(session, now)
		}
		session = &models.Session{ID: utils.NewID("cs"), Agent: event.Agent, StartedAt: now, LastActivity: now}
		session.RepoRoot, session.RepoBranch = detectGitContext(event.Target)
		_ = sm.store.InsertSession(session)
		sm.active[event.Agent] = session
	}

	session.LastActivity = now
	session.Duration = now.Sub(session.StartedAt)
	sm.updateCounters(session, event)
	_ = sm.store.UpdateSessionCounters(session)
	event.SessionID = session.ID
	return session
}

func (sm *SessionManager) isExpired(s *models.Session, now time.Time) bool {
	idle := now.Sub(s.LastActivity) > SessionIdleTimeout
	tooOld := now.Sub(s.StartedAt) > SessionMaxDuration
	return idle || tooOld
}

func (sm *SessionManager) CloseAll() {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	now := time.Now()
	for _, s := range sm.active {
		sm.closeSessionLocked(s, now)
	}
	sm.active = map[models.AgentID]*models.Session{}
}

func (sm *SessionManager) closeSessionLocked(s *models.Session, now time.Time) {
	s.EndedAt = &now
	s.Duration = now.Sub(s.StartedAt)
	s.LastActivity = now
	_ = sm.store.CloseSession(s)
}

func (sm *SessionManager) updateCounters(s *models.Session, e *models.AgentEvent) {
	switch e.ActionType {
	case models.ActionFileWrite:
		s.FileWrites++
	case models.ActionFileCreate:
		s.FileCreates++
	case models.ActionFileDelete:
		s.FileDeletes++
	case models.ActionExec:
		s.ExecCount++
	case models.ActionNetConnect:
		s.NetCount++
	}
	if e.RiskScore > s.MaxRisk {
		s.MaxRisk = e.RiskScore
	}
	for _, label := range e.RiskLabels {
		if !contains(s.TopRiskLabels, label) {
			s.TopRiskLabels = append(s.TopRiskLabels, label)
		}
	}
}

func detectGitContext(target string) (*string, *string) {
	dir := target
	if dir == "" {
		dir = "."
	}
	if !strings.HasPrefix(filepath.Base(dir), ".") {
		dir = filepath.Dir(dir)
	}
	rootBytes, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return nil, nil
	}
	branchBytes, err := exec.Command("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		return nil, nil
	}
	root := strings.TrimSpace(string(rootBytes))
	branch := strings.TrimSpace(string(branchBytes))
	return &root, &branch
}

func contains(items []string, v string) bool {
	for _, item := range items {
		if item == v {
			return true
		}
	}
	return false
}
