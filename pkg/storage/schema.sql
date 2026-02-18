PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA cache_size=10000;
PRAGMA temp_store=MEMORY;

CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    agent           TEXT NOT NULL,
    started_at      INTEGER NOT NULL,
    ended_at        INTEGER,
    duration_ms     INTEGER,
    last_activity   INTEGER NOT NULL,
    cwds            TEXT,
    repo_root       TEXT,
    repo_branch     TEXT,
    file_writes     INTEGER DEFAULT 0,
    file_creates    INTEGER DEFAULT 0,
    file_deletes    INTEGER DEFAULT 0,
    exec_count      INTEGER DEFAULT 0,
    net_count       INTEGER DEFAULT 0,
    max_risk        INTEGER DEFAULT 0,
    top_risk_labels TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_agent_time
    ON sessions(agent, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_started
    ON sessions(started_at DESC);

CREATE TABLE IF NOT EXISTS events_exec (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(id),
    timestamp   INTEGER NOT NULL,
    command     TEXT NOT NULL,
    args        TEXT,
    cwd         TEXT,
    risk_score  INTEGER DEFAULT 0,
    risk_labels TEXT
);

CREATE INDEX IF NOT EXISTS idx_exec_session
    ON events_exec(session_id, timestamp);

CREATE TABLE IF NOT EXISTS events_net (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES sessions(id),
    timestamp     INTEGER NOT NULL,
    remote_ip     TEXT NOT NULL,
    remote_port   INTEGER NOT NULL,
    domain        TEXT,
    protocol      TEXT DEFAULT 'tcp',
    bytes_sent    INTEGER DEFAULT 0,
    bytes_recv    INTEGER DEFAULT 0,
    is_ai_endpoint INTEGER DEFAULT 0,
    risk_score    INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_net_session
    ON events_net(session_id, timestamp);

CREATE TABLE IF NOT EXISTS session_files (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES sessions(id),
    file_path     TEXT NOT NULL,
    change_type   TEXT NOT NULL,
    lines_added   INTEGER DEFAULT 0,
    lines_removed INTEGER DEFAULT 0,
    save_count    INTEGER DEFAULT 0,
    first_seen    INTEGER NOT NULL,
    last_seen     INTEGER NOT NULL,
    snapshot_id   TEXT,
    is_redacted   INTEGER DEFAULT 0,

    UNIQUE(session_id, file_path)
);

CREATE INDEX IF NOT EXISTS idx_session_files_session
    ON session_files(session_id);

CREATE TABLE IF NOT EXISTS snapshots (
    id              TEXT PRIMARY KEY,
    session_file_id TEXT NOT NULL REFERENCES session_files(id),
    captured_at     INTEGER NOT NULL,
    before_text     BLOB,
    after_text      BLOB,
    before_hash     TEXT,
    after_hash      TEXT,
    lines_added     INTEGER DEFAULT 0,
    lines_removed   INTEGER DEFAULT 0,
    compressed      INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS dns_cache (
    ip          TEXT PRIMARY KEY,
    domain      TEXT NOT NULL,
    resolved_at INTEGER NOT NULL,
    ttl_seconds INTEGER DEFAULT 300
);
