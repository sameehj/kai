package attribution

import (
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
	"github.com/kai-ai/kai/pkg/utils"
)

type Engine struct {
	mu       sync.RWMutex
	sm       *SessionManager
	dnsCache *DNSCache
	store    *storage.DB
	watchers []chan models.AgentEvent
	pidAgent map[int]models.AgentID
}

func NewEngine(store *storage.DB) *Engine {
	cache := NewDNSCache(store)
	PreResolveKnownDomains(cache)
	return &Engine{sm: NewSessionManager(store), dnsCache: cache, store: store, pidAgent: map[int]models.AgentID{}}
}

func (e *Engine) Watch(ch chan models.AgentEvent) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.watchers = append(e.watchers, ch)
}

func (e *Engine) Close() {
	e.sm.CloseAll()
}

func (e *Engine) Process(raw models.RawEvent) *models.AgentEvent {
	ae := models.AgentEvent{
		ID:          utils.NewID("ev"),
		Timestamp:   raw.Timestamp,
		ActionType:  raw.ActionType,
		Target:      raw.Target,
		ExecArgs:    raw.ExecArgs,
		PID:         raw.PID,
		ProcessName: raw.ProcessName,
		Platform:    raw.Platform,
		Agent:       e.classify(raw, raw.Timestamp),
	}
	if ae.Agent == models.AgentUnknown {
		return nil
	}
	score, labels := ScoreEvent(&ae)
	ae.RiskScore = score
	ae.RiskLabels = labels

	session := e.sm.OnEvent(&ae)
	e.persist(session, &ae)
	if raw.PID > 0 {
		e.mu.Lock()
		e.pidAgent[raw.PID] = ae.Agent
		e.mu.Unlock()
	}

	e.mu.RLock()
	watchers := append([]chan models.AgentEvent(nil), e.watchers...)
	e.mu.RUnlock()
	for _, w := range watchers {
		select {
		case w <- ae:
		default:
		}
	}
	return &ae
}

func (e *Engine) classify(raw models.RawEvent, now time.Time) models.AgentID {
	for _, sig := range Signatures {
		for _, name := range sig.ProcessNames {
			if strings.EqualFold(raw.ProcessName, name) || strings.EqualFold(filepath.Base(raw.ProcessName), name) {
				return sig.ID
			}
		}
	}
	if raw.ActionType != models.ActionNetConnect {
		e.mu.RLock()
		if id, ok := e.pidAgent[raw.PID]; ok {
			e.mu.RUnlock()
			return id
		}
		if id, ok := e.pidAgent[raw.PPID]; ok {
			e.mu.RUnlock()
			return id
		}
		e.mu.RUnlock()
	}

	if raw.ActionType == models.ActionNetConnect {
		if id, ok := AgentForDomain(raw.Target); ok {
			return id
		}
		host, port := splitHostPort(raw.Target)
		if id, ok := AgentForDomain(host); ok {
			return id
		}
		if domain, isAI := e.dnsCache.ResolveIP(host, port); isAI && domain != nil {
			if id, ok := AgentForDomain(*domain); ok {
				return id
			}
		}
	}
	if raw.ActionType == models.ActionFileWrite || raw.ActionType == models.ActionFileCreate || raw.ActionType == models.ActionFileDelete {
		if guessed, ok := e.sm.GuessActiveAgent(now); ok {
			return guessed
		}
	}
	return models.AgentUnknown
}

func (e *Engine) persist(session *models.Session, ev *models.AgentEvent) {
	switch ev.ActionType {
	case models.ActionExec:
		_ = e.store.InsertExecEvent(&models.ExecEvent{
			ID:         ev.ID,
			SessionID:  session.ID,
			Timestamp:  ev.Timestamp,
			Command:    ev.Target,
			Args:       ev.ExecArgs,
			RiskScore:  ev.RiskScore,
			RiskLabels: ev.RiskLabels,
		})
	case models.ActionNetConnect:
		ip, port := splitHostPort(ev.Target)
		domain, isAI := e.dnsCache.ResolveIP(ip, port)
		_ = e.store.InsertNetEvent(&models.NetEvent{
			ID:           ev.ID,
			SessionID:    session.ID,
			Timestamp:    ev.Timestamp,
			RemoteIP:     ip,
			RemotePort:   port,
			Domain:       domain,
			Protocol:     "tcp",
			IsAIEndpoint: isAI,
			RiskScore:    ev.RiskScore,
		})
	}
}

func splitHostPort(v string) (string, int) {
	raw := strings.TrimSpace(v)
	if raw == "" {
		return "", 0
	}

	// Best case: standard host:port or [ipv6]:port
	if h, p, err := net.SplitHostPort(raw); err == nil {
		port, _ := strconv.Atoi(p)
		return strings.Trim(h, "[]"), port
	}

	// Fallback: take last ':' as port separator.
	i := strings.LastIndex(raw, ":")
	if i < 0 || i == len(raw)-1 {
		return strings.Trim(raw, "[]"), 0
	}
	hostPart := strings.Trim(raw[:i], "[]")
	portPart := raw[i+1:]
	port := 0
	for _, c := range portPart {
		if c < '0' || c > '9' {
			return hostPart, 0
		}
		port = port*10 + int(c-'0')
	}
	return hostPart, port
}

func NewRawEvent(action models.ActionType, processName, target string, pid int) models.RawEvent {
	return models.RawEvent{Timestamp: time.Now(), PID: pid, ProcessName: processName, ActionType: action, Target: target}
}
