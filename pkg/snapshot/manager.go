package snapshot

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kai-ai/kai/pkg/models"
	"github.com/kai-ai/kai/pkg/storage"
	"github.com/kai-ai/kai/pkg/utils"
)

const (
	QuietPeriod    = 400 * time.Millisecond
	MaxQuietPeriod = 2 * time.Second
)

type Config struct {
	SnapshotEnabled      bool
	MaxSnapshotSizeBytes int
	SkipExtensions       map[string]struct{}
	ExtraSkipPaths       []string
}

type pendingFile struct {
	sessionID  string
	filePath   string
	changeType models.FileChangeType
	firstSeen  time.Time
	lastSeen   time.Time
	eventCount int
	beforeText *[]byte
	beforeHash *string
	quietTimer *time.Timer
	forceTimer *time.Timer
}

type Manager struct {
	mu      sync.Mutex
	pending map[string]*pendingFile
	store   *storage.DB
	cfg     Config
}

func NewManager(store *storage.DB, cfg Config) *Manager {
	return &Manager{store: store, cfg: cfg, pending: map[string]*pendingFile{}}
}

func (m *Manager) OnFileEvent(sessionID, path string, changeType models.FileChangeType) {
	if !m.cfg.SnapshotEnabled || m.isPrivacyPath(path) || m.isSkippedExtension(path) {
		return
	}
	key := sessionID + ":" + path

	m.mu.Lock()
	pf, ok := m.pending[key]
	if !ok {
		before := m.readBefore(sessionID, path)
		pf = &pendingFile{sessionID: sessionID, filePath: path, changeType: changeType, firstSeen: time.Now(), beforeText: before, beforeHash: hashOf(before)}
		m.pending[key] = pf
		pf.forceTimer = time.AfterFunc(MaxQuietPeriod, func() { m.flush(key) })
	}
	pf.lastSeen = time.Now()
	pf.eventCount++
	if pf.quietTimer != nil {
		pf.quietTimer.Stop()
	}
	pf.quietTimer = time.AfterFunc(QuietPeriod, func() { m.flush(key) })
	m.mu.Unlock()
}

func (m *Manager) OnFileDelete(sessionID, path string) {
	m.OnFileEvent(sessionID, path, models.FileDeleted)
	m.flush(sessionID + ":" + path)
}

func (m *Manager) FlushAll() {
	m.mu.Lock()
	keys := make([]string, 0, len(m.pending))
	for k := range m.pending {
		keys = append(keys, k)
	}
	m.mu.Unlock()
	for _, key := range keys {
		m.flush(key)
	}
}

func (m *Manager) flush(key string) {
	m.mu.Lock()
	pf, ok := m.pending[key]
	if !ok {
		m.mu.Unlock()
		return
	}
	delete(m.pending, key)
	m.mu.Unlock()
	m.commitSnapshot(pf)
}

func (m *Manager) commitSnapshot(pf *pendingFile) {
	after := readFile(pf.filePath, m.cfg.MaxSnapshotSizeBytes)
	before := pf.beforeText
	beforeHash := pf.beforeHash
	afterHash := hashOf(after)

	if beforeHash != nil && afterHash != nil && *beforeHash == *afterHash {
		before = nil
		beforeHash = nil
	}

	redacted := false
	if before != nil {
		b := redact(*before)
		before = &b
	}
	if after != nil {
		a := redact(*after)
		after = &a
	}
	if (before != nil && isBinary(*before)) || (after != nil && isBinary(*after)) {
		before, after = nil, nil
		redacted = true
	}

	linesAdded, linesRemoved := lineDelta(before, after)
	sf := &models.SessionFile{
		ID:           utils.NewID("sf"),
		SessionID:    pf.sessionID,
		FilePath:     pf.filePath,
		ChangeType:   pf.changeType,
		LinesAdded:   linesAdded,
		LinesRemoved: linesRemoved,
		SaveCount:    pf.eventCount,
		FirstSeen:    pf.firstSeen,
		LastSeen:     pf.lastSeen,
		IsRedacted:   redacted,
	}

	snap := &models.Snapshot{
		ID:            utils.NewID("sn"),
		SessionFileID: sf.ID,
		CapturedAt:    time.Now(),
		BeforeText:    gzipBytes(before),
		AfterText:     gzipBytes(after),
		BeforeHash:    beforeHash,
		AfterHash:     afterHash,
		LinesAdded:    linesAdded,
		LinesRemoved:  linesRemoved,
		Compressed:    true,
	}
	_ = m.store.UpsertSessionFile(sf, snap)
}

func (m *Manager) readBefore(sessionID, path string) *[]byte {
	if prior := m.store.GetLatestSnapshotContent(sessionID, path); prior != nil {
		if b, err := gunzip(*prior); err == nil {
			return &b
		}
	}
	return readFile(path, m.cfg.MaxSnapshotSizeBytes)
}

func (m *Manager) isSkippedExtension(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	_, ok := m.cfg.SkipExtensions[ext]
	return ok
}

func (m *Manager) isPrivacyPath(path string) bool {
	lower := strings.ToLower(path)
	defaults := []string{".env", ".pem", ".key", "id_rsa", "id_ed25519", ".ssh/", "secret", "credential", "password"}
	for _, p := range defaults {
		if strings.Contains(lower, p) {
			return true
		}
	}
	for _, p := range m.cfg.ExtraSkipPaths {
		if strings.Contains(lower, strings.ToLower(p)) {
			return true
		}
	}
	return false
}

func readFile(path string, maxSize int) *[]byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	buf := make([]byte, maxSize)
	n, err := f.Read(buf)
	if err != nil && err != io.EOF {
		return nil
	}
	b := append([]byte(nil), buf[:n]...)
	return &b
}

func hashOf(v *[]byte) *string {
	if v == nil {
		return nil
	}
	h := sha256.Sum256(*v)
	s := strings.ToLower(fmtHex(h[:]))
	return &s
}

func fmtHex(b []byte) string {
	const hexdigits = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[i*2] = hexdigits[v>>4]
		out[i*2+1] = hexdigits[v&0x0f]
	}
	return string(out)
}

func redact(in []byte) []byte {
	s := string(in)
	patterns := []string{"OPENAI_API_KEY=", "ANTHROPIC_API_KEY=", "AWS_SECRET_ACCESS_KEY=", "AWS_ACCESS_KEY_ID=", "ghp_", "sk-"}
	for _, p := range patterns {
		s = redactKeyValue(s, p)
	}
	return []byte(s)
}

func redactKeyValue(s, marker string) string {
	idx := strings.Index(s, marker)
	for idx >= 0 {
		end := strings.IndexByte(s[idx:], '\n')
		if end < 0 {
			s = s[:idx] + marker + "[REDACTED]"
			break
		}
		s = s[:idx] + marker + "[REDACTED]" + s[idx+end:]
		idx = strings.Index(s, marker)
	}
	return s
}

func isBinary(content []byte) bool {
	if len(content) == 0 {
		return false
	}
	nuls := bytes.Count(content, []byte{0})
	return nuls*10 > len(content)
}

func lineDelta(before, after *[]byte) (int, int) {
	if before == nil && after == nil {
		return 0, 0
	}
	if before == nil {
		return lines(*after), 0
	}
	if after == nil {
		return 0, lines(*before)
	}
	b := lines(*before)
	a := lines(*after)
	if a >= b {
		return a - b, 0
	}
	return 0, b - a
}

func lines(v []byte) int {
	if len(v) == 0 {
		return 0
	}
	return bytes.Count(v, []byte("\n")) + 1
}

func gzipBytes(v *[]byte) *[]byte {
	if v == nil {
		return nil
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(*v)
	_ = zw.Close()
	b := buf.Bytes()
	return &b
}

func gunzip(v []byte) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(v))
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	return io.ReadAll(zr)
}
