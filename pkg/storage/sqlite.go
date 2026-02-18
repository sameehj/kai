package storage

import (
	"database/sql"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/kai-ai/kai/pkg/models"
)

//go:embed schema.sql
var schemaSQL string

type DB struct {
	db *sql.DB
}

type ReplayResult struct {
	Session   models.Session
	Files     []models.SessionFile
	Snapshots map[string]*models.Snapshot
	Execs     []models.ExecEvent
	NetEvents []models.NetEvent
}

func Open(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}

	pragmas := []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA foreign_keys=ON",
		"PRAGMA cache_size=10000",
		"PRAGMA temp_store=MEMORY",
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			return nil, fmt.Errorf("pragma %s: %w", p, err)
		}
	}

	if _, err := db.Exec(schemaSQL); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}

	return &DB{db: db}, nil
}

func (d *DB) Close() error { return d.db.Close() }

func ts(t time.Time) int64      { return t.UnixMilli() }
func fromTS(ms int64) time.Time { return time.UnixMilli(ms) }

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func parseJSONArray[T any](s sql.NullString) []T {
	if !s.Valid || strings.TrimSpace(s.String) == "" {
		return nil
	}
	var out []T
	_ = json.Unmarshal([]byte(s.String), &out)
	return out
}

func (d *DB) InsertSession(s *models.Session) error {
	_, err := d.db.Exec(`
		INSERT INTO sessions (
			id, agent, started_at, ended_at, duration_ms, last_activity,
			cwds, repo_root, repo_branch,
			file_writes, file_creates, file_deletes, exec_count, net_count, max_risk, top_risk_labels
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		s.ID,
		string(s.Agent),
		ts(s.StartedAt),
		nullTS(s.EndedAt),
		s.Duration.Milliseconds(),
		ts(s.LastActivity),
		mustJSON(s.CWDs),
		nullStr(s.RepoRoot),
		nullStr(s.RepoBranch),
		s.FileWrites,
		s.FileCreates,
		s.FileDeletes,
		s.ExecCount,
		s.NetCount,
		s.MaxRisk,
		mustJSON(s.TopRiskLabels),
	)
	return err
}

func (d *DB) UpdateSessionCounters(s *models.Session) error {
	_, err := d.db.Exec(`
		UPDATE sessions SET
			last_activity=?,
			duration_ms=?,
			cwds=?,
			file_writes=?,
			file_creates=?,
			file_deletes=?,
			exec_count=?,
			net_count=?,
			max_risk=?,
			top_risk_labels=?
		WHERE id=?
	`,
		ts(s.LastActivity),
		s.Duration.Milliseconds(),
		mustJSON(s.CWDs),
		s.FileWrites,
		s.FileCreates,
		s.FileDeletes,
		s.ExecCount,
		s.NetCount,
		s.MaxRisk,
		mustJSON(s.TopRiskLabels),
		s.ID,
	)
	return err
}

func (d *DB) CloseSession(s *models.Session) error {
	if s.EndedAt == nil {
		now := time.Now()
		s.EndedAt = &now
		s.Duration = now.Sub(s.StartedAt)
	}
	_, err := d.db.Exec(
		"UPDATE sessions SET ended_at=?, duration_ms=?, last_activity=? WHERE id=?",
		ts(*s.EndedAt), s.Duration.Milliseconds(), ts(s.LastActivity), s.ID,
	)
	return err
}

func (d *DB) InsertExecEvent(e *models.ExecEvent) error {
	_, err := d.db.Exec(`
		INSERT INTO events_exec (id, session_id, timestamp, command, args, cwd, risk_score, risk_labels)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, e.ID, e.SessionID, ts(e.Timestamp), e.Command, mustJSON(e.Args), e.CWD, e.RiskScore, mustJSON(e.RiskLabels))
	return err
}

func (d *DB) InsertNetEvent(e *models.NetEvent) error {
	_, err := d.db.Exec(`
		INSERT INTO events_net (id, session_id, timestamp, remote_ip, remote_port, domain, protocol, bytes_sent, bytes_recv, is_ai_endpoint, risk_score)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, e.ID, e.SessionID, ts(e.Timestamp), e.RemoteIP, e.RemotePort, nullStr(e.Domain), e.Protocol, e.BytesSent, e.BytesRecv, boolInt(e.IsAIEndpoint), e.RiskScore)
	return err
}

func (d *DB) UpsertSessionFile(sf *models.SessionFile, snap *models.Snapshot) error {
	tx, err := d.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if snap != nil {
		_, err = tx.Exec(`
			INSERT OR REPLACE INTO snapshots (id, session_file_id, captured_at, before_text, after_text, before_hash, after_hash, lines_added, lines_removed, compressed)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, snap.ID, snap.SessionFileID, ts(snap.CapturedAt), nilOrBytes(snap.BeforeText), nilOrBytes(snap.AfterText), nullStr(snap.BeforeHash), nullStr(snap.AfterHash), snap.LinesAdded, snap.LinesRemoved, boolInt(snap.Compressed))
		if err != nil {
			return err
		}
		sf.SnapshotID = &snap.ID
	}

	_, err = tx.Exec(`
		INSERT INTO session_files (
			id, session_id, file_path, change_type, lines_added, lines_removed, save_count, first_seen, last_seen, snapshot_id, is_redacted
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(session_id, file_path) DO UPDATE SET
			change_type=excluded.change_type,
			lines_added=excluded.lines_added,
			lines_removed=excluded.lines_removed,
			save_count=excluded.save_count,
			last_seen=excluded.last_seen,
			snapshot_id=excluded.snapshot_id,
			is_redacted=excluded.is_redacted
	`, sf.ID, sf.SessionID, sf.FilePath, string(sf.ChangeType), sf.LinesAdded, sf.LinesRemoved, sf.SaveCount, ts(sf.FirstSeen), ts(sf.LastSeen), nullStr(sf.SnapshotID), boolInt(sf.IsRedacted))
	if err != nil {
		return err
	}

	return tx.Commit()
}

func (d *DB) GetLatestSnapshotContent(sessionID, path string) *[]byte {
	var content []byte
	err := d.db.QueryRow(`
		SELECT s.after_text
		FROM snapshots s
		JOIN session_files sf ON sf.id = s.session_file_id
		WHERE sf.session_id = ? AND sf.file_path = ? AND s.after_text IS NOT NULL
		ORDER BY s.captured_at DESC LIMIT 1
	`, sessionID, path).Scan(&content)
	if err != nil {
		return nil
	}
	return &content
}

func (d *DB) GetLastSession(agent *models.AgentID) (*models.Session, error) {
	q := `
		SELECT id, agent, started_at, ended_at, duration_ms, last_activity,
			cwds, repo_root, repo_branch, file_writes, file_creates, file_deletes,
			exec_count, net_count, max_risk, top_risk_labels
		FROM sessions`
	var args []any
	if agent != nil {
		q += " WHERE agent=?"
		args = append(args, string(*agent))
	}
	q += " ORDER BY started_at DESC LIMIT 1"

	return scanSession(d.db.QueryRow(q, args...))
}

func (d *DB) GetSessions(limit int, agent *models.AgentID) ([]models.Session, error) {
	q := `
		SELECT id, agent, started_at, ended_at, duration_ms, last_activity,
			cwds, repo_root, repo_branch, file_writes, file_creates, file_deletes,
			exec_count, net_count, max_risk, top_risk_labels
		FROM sessions`
	var args []any
	if agent != nil {
		q += " WHERE agent=?"
		args = append(args, string(*agent))
	}
	q += " ORDER BY started_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := d.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]models.Session, 0, limit)
	for rows.Next() {
		s, err := scanSessionRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func (d *DB) GetReplay(sessionID string) (*ReplayResult, error) {
	s, err := d.getSessionByID(sessionID)
	if err != nil {
		return nil, err
	}
	res := &ReplayResult{Session: *s, Snapshots: map[string]*models.Snapshot{}}

	fileRows, err := d.db.Query(`
		SELECT id, session_id, file_path, change_type, lines_added, lines_removed, save_count,
			first_seen, last_seen, snapshot_id, is_redacted
		FROM session_files WHERE session_id=? ORDER BY file_path
	`, sessionID)
	if err != nil {
		return nil, err
	}
	defer fileRows.Close()
	for fileRows.Next() {
		var f models.SessionFile
		var ct string
		var fs, ls int64
		var sid sql.NullString
		var red int
		if err := fileRows.Scan(&f.ID, &f.SessionID, &f.FilePath, &ct, &f.LinesAdded, &f.LinesRemoved, &f.SaveCount, &fs, &ls, &sid, &red); err != nil {
			return nil, err
		}
		f.ChangeType = models.FileChangeType(ct)
		f.FirstSeen = fromTS(fs)
		f.LastSeen = fromTS(ls)
		if sid.Valid {
			f.SnapshotID = &sid.String
		}
		f.IsRedacted = red == 1
		res.Files = append(res.Files, f)
	}

	execRows, err := d.db.Query(`
		SELECT id, session_id, timestamp, command, args, cwd, risk_score, risk_labels
		FROM events_exec WHERE session_id=? ORDER BY timestamp
	`, sessionID)
	if err != nil {
		return nil, err
	}
	defer execRows.Close()
	for execRows.Next() {
		var e models.ExecEvent
		var tsv int64
		var args, labels sql.NullString
		if err := execRows.Scan(&e.ID, &e.SessionID, &tsv, &e.Command, &args, &e.CWD, &e.RiskScore, &labels); err != nil {
			return nil, err
		}
		e.Timestamp = fromTS(tsv)
		e.Args = parseJSONArray[string](args)
		e.RiskLabels = parseJSONArray[string](labels)
		res.Execs = append(res.Execs, e)
	}

	netRows, err := d.db.Query(`
		SELECT id, session_id, timestamp, remote_ip, remote_port, domain, protocol, bytes_sent, bytes_recv, is_ai_endpoint, risk_score
		FROM events_net WHERE session_id=? ORDER BY timestamp
	`, sessionID)
	if err != nil {
		return nil, err
	}
	defer netRows.Close()
	for netRows.Next() {
		var n models.NetEvent
		var tsv int64
		var domain sql.NullString
		var ai int
		if err := netRows.Scan(&n.ID, &n.SessionID, &tsv, &n.RemoteIP, &n.RemotePort, &domain, &n.Protocol, &n.BytesSent, &n.BytesRecv, &ai, &n.RiskScore); err != nil {
			return nil, err
		}
		n.Timestamp = fromTS(tsv)
		if domain.Valid {
			n.Domain = &domain.String
		}
		n.IsAIEndpoint = ai == 1
		res.NetEvents = append(res.NetEvents, n)
	}

	sRows, err := d.db.Query(`
		SELECT id, session_file_id, captured_at, before_text, after_text, before_hash, after_hash, lines_added, lines_removed, compressed
		FROM snapshots
		WHERE session_file_id IN (SELECT id FROM session_files WHERE session_id=?)
	`, sessionID)
	if err != nil {
		return nil, err
	}
	defer sRows.Close()
	for sRows.Next() {
		var s models.Snapshot
		var tsv int64
		var bt, at []byte
		var bh, ah sql.NullString
		var comp int
		if err := sRows.Scan(&s.ID, &s.SessionFileID, &tsv, &bt, &at, &bh, &ah, &s.LinesAdded, &s.LinesRemoved, &comp); err != nil {
			return nil, err
		}
		s.CapturedAt = fromTS(tsv)
		if bt != nil {
			s.BeforeText = &bt
		}
		if at != nil {
			s.AfterText = &at
		}
		if bh.Valid {
			s.BeforeHash = &bh.String
		}
		if ah.Valid {
			s.AfterHash = &ah.String
		}
		s.Compressed = comp == 1
		res.Snapshots[s.SessionFileID] = &s
	}

	return res, nil
}

func (d *DB) GetDNSEntry(ip string) (string, bool) {
	var domain string
	var resolvedAt int64
	var ttl int64
	err := d.db.QueryRow("SELECT domain, resolved_at, ttl_seconds FROM dns_cache WHERE ip=?", ip).Scan(&domain, &resolvedAt, &ttl)
	if err != nil {
		return "", false
	}
	if time.Since(fromTS(resolvedAt)) > time.Duration(ttl)*time.Second {
		return "", false
	}
	return domain, true
}

func (d *DB) SetDNSEntry(ip, domain string, ttl time.Duration) error {
	_, err := d.db.Exec(`
		INSERT INTO dns_cache(ip, domain, resolved_at, ttl_seconds)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(ip) DO UPDATE SET domain=excluded.domain, resolved_at=excluded.resolved_at, ttl_seconds=excluded.ttl_seconds
	`, ip, domain, ts(time.Now()), int(ttl.Seconds()))
	return err
}

func (d *DB) PurgeOlderThan(olderThan time.Duration) error {
	cutoff := ts(time.Now().Add(-olderThan))
	_, err := d.db.Exec("DELETE FROM sessions WHERE started_at < ?", cutoff)
	return err
}

func (d *DB) getSessionByID(id string) (*models.Session, error) {
	return scanSession(d.db.QueryRow(`
		SELECT id, agent, started_at, ended_at, duration_ms, last_activity,
			cwds, repo_root, repo_branch, file_writes, file_creates, file_deletes,
			exec_count, net_count, max_risk, top_risk_labels
		FROM sessions WHERE id=?
	`, id))
}

func scanSession(row *sql.Row) (*models.Session, error) {
	var s models.Session
	var agent string
	var started, last int64
	var ended sql.NullInt64
	var duration sql.NullInt64
	var cwds, labels sql.NullString
	var repoRoot, repoBranch sql.NullString
	if err := row.Scan(
		&s.ID, &agent, &started, &ended, &duration, &last,
		&cwds, &repoRoot, &repoBranch,
		&s.FileWrites, &s.FileCreates, &s.FileDeletes, &s.ExecCount, &s.NetCount, &s.MaxRisk, &labels,
	); err != nil {
		return nil, err
	}
	s.Agent = models.AgentID(agent)
	s.StartedAt = fromTS(started)
	if ended.Valid {
		t := fromTS(ended.Int64)
		s.EndedAt = &t
	}
	if duration.Valid {
		s.Duration = time.Duration(duration.Int64) * time.Millisecond
	}
	s.LastActivity = fromTS(last)
	s.CWDs = parseJSONArray[string](cwds)
	if repoRoot.Valid {
		s.RepoRoot = &repoRoot.String
	}
	if repoBranch.Valid {
		s.RepoBranch = &repoBranch.String
	}
	s.TopRiskLabels = parseJSONArray[string](labels)
	return &s, nil
}

func scanSessionRow(rows *sql.Rows) (*models.Session, error) {
	var s models.Session
	var agent string
	var started, last int64
	var ended sql.NullInt64
	var duration sql.NullInt64
	var cwds, labels sql.NullString
	var repoRoot, repoBranch sql.NullString
	if err := rows.Scan(
		&s.ID, &agent, &started, &ended, &duration, &last,
		&cwds, &repoRoot, &repoBranch,
		&s.FileWrites, &s.FileCreates, &s.FileDeletes, &s.ExecCount, &s.NetCount, &s.MaxRisk, &labels,
	); err != nil {
		return nil, err
	}
	s.Agent = models.AgentID(agent)
	s.StartedAt = fromTS(started)
	if ended.Valid {
		t := fromTS(ended.Int64)
		s.EndedAt = &t
	}
	if duration.Valid {
		s.Duration = time.Duration(duration.Int64) * time.Millisecond
	}
	s.LastActivity = fromTS(last)
	s.CWDs = parseJSONArray[string](cwds)
	if repoRoot.Valid {
		s.RepoRoot = &repoRoot.String
	}
	if repoBranch.Valid {
		s.RepoBranch = &repoBranch.String
	}
	s.TopRiskLabels = parseJSONArray[string](labels)
	return &s, nil
}

func nullStr(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

func nullTS(t *time.Time) any {
	if t == nil {
		return nil
	}
	return ts(*t)
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func nilOrBytes(v *[]byte) any {
	if v == nil {
		return nil
	}
	return *v
}
