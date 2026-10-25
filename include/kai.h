/*
 * Kai — open-source security layer for AI agents.
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * This is the public, embeddable C API of libkai. Everything else in the
 * project (hooks, CLI, installer) is built on these functions.
 */
#ifndef KAI_H
#define KAI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KAI_VERSION "0.1.0"

/* What to do when a rule matches. Ordered by severity. */
typedef enum {
    KAI_ACT_NONE = 0,
    KAI_ACT_WARN = 1,    /* log only, text unchanged                 */
    KAI_ACT_REPLACE = 2, /* swap the match for policy-defined text   */
    KAI_ACT_REDACT = 3,  /* swap the match for a [REDACTED…] marker  */
    KAI_ACT_BLOCK = 4    /* refuse the whole action / request        */
} kai_action;

#define KAI_MAX_HITS 64
#define KAI_NAME_MAX 64

typedef struct {
    char rule[KAI_NAME_MAX];
    kai_action action;
    int count;
} kai_hit;

/* Summary of one scan. Never contains the matched secret itself. */
typedef struct {
    kai_hit hits[KAI_MAX_HITS];
    int nhits;
    kai_action worst;
    int skipped; /* text too large to scan */
} kai_report;

typedef struct kai_policy kai_policy;

/* Load the policy. path == NULL means $KAI_POLICY, then ~/.kai/policy,
 * then the built-in defaults. Returns NULL and fills err on a parse error. */
kai_policy *kai_policy_load(const char *path, char *err, size_t errlen);
kai_policy *kai_policy_from_string(const char *text, char *err, size_t errlen);
void kai_policy_free(kai_policy *p);
const char *kai_policy_source(const kai_policy *p); /* file path or "built-in" */

/* The built-in default policy text (what `kai init` writes). */
const char *kai_default_policy(void);

/* Scan text against content rules. Returns a newly allocated copy with
 * redact/replace/block rules applied (caller frees). rep may be NULL. */
char *kai_scan_text(const kai_policy *p, const char *text, kai_report *rep);

/* Is this path protected (secrets, keys, Kai itself)? cwd resolves relative
 * paths; why receives the matching pattern. Returns 1 if protected. */
int kai_path_protected(const kai_policy *p, const char *path, const char *cwd,
                       char *why, size_t whylen);

/* Does a shell command touch a protected path? Returns 1 and fills why. */
int kai_command_touches_protected(const kai_policy *p, const char *cmd,
                                  const char *cwd, char *why, size_t whylen);

/* Does a shell command look like it uploads data or pipes remote code into
 * a shell? Returns 1 and fills why with the pattern name. */
int kai_command_looks_like_upload(const kai_policy *p, const char *cmd,
                                  char *why, size_t whylen);

/* Does text contain instructions aimed at an AI agent (prompt injection)?
 * Returns the number of patterns matched; which receives the first name. */
int kai_injection_check(const kai_policy *p, const char *text, char *which,
                        size_t whichlen);

/* Weighs evidence that text addresses an AI agent with instructions, instead
 * of firing on any keyword. Matches inside code blocks, inline code, quoted
 * examples and policy/config lines don't count; phrasing as a command,
 * addressing the agent, and hiding (HTML comments, invisible characters)
 * add weight. snippet holds a short excerpt around the strongest match with
 * secrets already redacted, safe to log. */
#define KAI_INJECTION_WARN 4 /* score at which Kai warns (tuned on tests/corpus) */
typedef struct {
    int score;                 /* 0 = nothing; >= KAI_INJECTION_WARN = warn  */
    int rules;                 /* distinct patterns that matched in prose     */
    int hidden;                /* found in an HTML comment / invisible text   */
    char rule[KAI_NAME_MAX];   /* strongest pattern                           */
    char snippet[240];
} kai_injection_finding;
int kai_injection_assess(const kai_policy *p, const char *text, kai_injection_finding *f);

/* Policy switches used by integrations. */
kai_action kai_policy_prompt_action(const kai_policy *p);      /* block | warn */
kai_action kai_policy_file_secret_action(const kai_policy *p); /* block | warn */
kai_action kai_policy_upload_action(const kai_policy *p);      /* block | ask(=warn) */

/* ---- Network wall: egress allowlist ----
 * Applies to traffic from agent processes (see kai_process_agent). */
typedef enum {
    KAI_EGRESS_OFF = 0,  /* no egress control                              */
    KAI_EGRESS_LOG = 1,  /* allow everything, log non-allowlisted hosts    */
    KAI_EGRESS_BLOCK = 2 /* drop agent traffic to non-allowlisted hosts    */
} kai_egress_mode;

kai_egress_mode kai_policy_egress_mode(const kai_policy *p);
/* Is host on the allowlist? An entry matches itself and its subdomains.
 * why receives the matching entry. Hosts are compared case-insensitively. */
int kai_egress_allowed(const kai_policy *p, const char *host, char *why, size_t whylen);

/* Is this connection allowed? host is the name the client asked for (TLS SNI,
 * HTTP Host, or the flow's own name), or NULL when none is known; ip is the
 * remote address (IPv6 may be in brackets); port is the remote port.
 * Loopback (127.0.0.0/8, ::1) is always allowed. Entries may be a host
 * (with its subdomains), an IP address or CIDR range, either with ":port":
 *   example.com  db.example.com:5432  10.0.0.0/8  203.0.113.5:22  [2001:db8::1]:22
 * why receives the matching entry. */
int kai_egress_endpoint_allowed(const kai_policy *p, const char *host, const char *ip, int port,
                                char *why, size_t whylen);
/* Is entry a valid egress_allow value (one of the forms above)? */
int kai_egress_entry_valid(const char *entry);

/* Is this protected-path rule one of Kai's built-in self-protection rules
 * (its own ~/.kai, the agents' hook settings) rather than a user secret rule?
 * `rule` is the value kai_path_protected / the storage wall fill into `why`. */
int kai_rule_is_builtin(const char *rule);
/* True if the matched builtin rule is Kai's own home (~/.kai): reads stay
 * blocked for agents (it holds the policy, audit log and approval key). */
int kai_rule_is_kai_home(const char *rule);
/* True if the matched builtin rule is an agent hook-config control path whose
 * READS are safe to allow (so the agent can start and Kai's hooks can load);
 * WRITES to it must still be blocked by the caller (anti-tamper). */
int kai_control_read_allowed(const char *rule);
/* True if `path` is Kai's own control store: the policy file, a file under the
 * grants dir, or a file under the pending-policy dir. These must never be
 * writable by an agent-tree process, Kai-signed or not (the storage wall uses
 * this to withhold the Kai-signature exemption from a tagged `kai` process). */
int kai_path_is_control_store(const char *path);
/* True if an Endpoint Security open event's `fflag` denotes a write-capable
 * open. `fflag` is in the kernel FREAD/FWRITE convention, not the O_RDONLY/
 * O_WRONLY/O_RDWR convention; see the definition. The storage wall uses this
 * to tell a read open from a write open. */
int kai_open_is_write(int fflag);
/* Dev-sandbox guard: abort the process if KAI_HOME is unset or resolves to the
 * user's real ~/.kai. Call at the top of every test main() so a test can never
 * run against (and corrupt) the real Kai home. */
void kai_require_sandbox_home(void);
/* 1 if the active Kai home is, or would default to, the user's real ~/.kai
 * (KAI_HOME unset/empty, or set to the real home). Used by the guard above. */
int kai_home_is_real(void);

/* Extract the server name (SNI) from the start of a TLS ClientHello.
 * Returns 1 and fills host if found, 0 if this is not TLS or carries no SNI,
 * -1 if more bytes are needed. Never reads past len. */
int kai_tls_sni(const unsigned char *buf, size_t len, char *host, size_t hostlen);

/* ---- Storage wall: which files agents may open ----
 * The OS layer (macOS Endpoint Security, when Apple grants the entitlement)
 * asks this for every open() by an agent process. The decision itself is
 * plain and testable here, with no OS involved. */
typedef enum {
    KAI_STORAGE_OFF = 0,   /* no file control (default)                      */
    KAI_STORAGE_LOG = 1,   /* allow everything, log agent opens of protected */
    KAI_STORAGE_BLOCK = 2  /* deny agent opens of protected paths            */
} kai_storage_mode;

kai_storage_mode kai_policy_storage_mode(const kai_policy *p);

/* May a process open this path? is_agent says the process is an AI agent or a
 * descendant of one (see kai_process_agent); write says it is opening for
 * write. Returns 1 (allow) or 0 (deny), and fills why with the matching rule
 * when it denies. A non-agent is always allowed. With the wall off or in log
 * mode the answer is always allow (the caller still logs a filled why). Kai's
 * own files (~/.kai) and agent hook settings are always denied to agents in
 * block mode, whatever the policy's allow list says. */
int kai_storage_open_allowed(const kai_policy *p, int is_agent, int write,
                             const char *path, char *why, size_t whylen);

/* ---- Scoped Approvals (M0 engine) ----
 * A grant narrows an existing denial for one verified identity, one resource,
 * one operation, for a bounded time. It can turn a SOFT-protected path into
 * allow, but NEVER an un-exemptable (builtin/control) path such as ~/.kai or an
 * agent's hook config. A grant is honored only if its HMAC verifies under the
 * approval key — which lives in a control-path-protected file the agent cannot
 * read — so an agent that writes a grant file cannot forge consent. See
 * docs/SCOPED_APPROVALS.md. Nothing here changes a wall's live state. */
typedef enum { KAI_OP_READ = 0, KAI_OP_WRITE = 1, KAI_OP_CONNECT = 2 } kai_grant_op;
typedef enum { KAI_GRANT_PROCESS = 0, KAI_GRANT_ONESHOT = 1 } kai_grant_scope;
typedef enum { KAI_ID_WEAK = 0, KAI_ID_MEDIUM = 1, KAI_ID_STRONG = 2 } kai_identity_strength;

#define KAI_GRANT_RES_MAX 1024
typedef struct {
    char id[40];
    long long created_utc;      /* epoch seconds                               */
    long long expires_utc;      /* epoch seconds; checked at enforcement time  */
    int pid;                    /* subject process                             */
    unsigned long long pidversion; /* audit-token pidversion (defeats pid reuse) */
    char agent[64];             /* classified agent name                       */
    int strength;               /* kai_identity_strength at issue time         */
    char resource[KAI_GRANT_RES_MAX]; /* canonical abs path (realpath) or endpoint */
    int op;                     /* kai_grant_op                                */
    int scope;                  /* kai_grant_scope                             */
    char approved_by[32];       /* "console-user" | "cli" (informational)      */
    int grant_version;          /* 1 (v1) or 2 (adds session/project/dest_kind) */
    char session_id[40];        /* v2: bind to one verified agent session; "" = any */
    char project[KAI_GRANT_RES_MAX]; /* v2: realpath at root exec; "" = any      */
    int dest_kind;              /* v2: kai_grant_dest (path | endpoint)          */
    char hmac[65];              /* hex HMAC-SHA256 over the canonical form      */
} kai_grant;

typedef enum { KAI_DEST_PATH = 0, KAI_DEST_ENDPOINT = 1 } kai_grant_dest;

/* The requesting process, at enforcement time. */
typedef struct {
    int pid;
    unsigned long long pidversion;
    const char *agent;          /* classified name, or NULL                    */
    int strength;               /* kai_identity_strength                       */
    const char *session_id;     /* v2: current verified session, or NULL        */
    const char *project;        /* v2: current project (realpath), or NULL      */
} kai_grant_subject;

/* Sign / verify a grant's canonical form with the approval key (raw bytes). */
void kai_grant_sign(kai_grant *g, const unsigned char *key, size_t keylen);
int  kai_grant_hmac_ok(const kai_grant *g, const unsigned char *key, size_t keylen);

/* JSON (one grant per file). to_json returns a malloc'd string (caller frees). */
char *kai_grant_to_json(const kai_grant *g);
int   kai_grant_from_json(const char *json, kai_grant *out); /* 1 ok, 0 parse err */
/* Build + sign a grant from scalar fields and return its JSON (caller frees).
 * Used by the app's approve action so Swift need not fill C fixed arrays. */
char *kai_grant_build_json(const char *id, long long created, long long expires,
                           int pid, unsigned long long pidversion, const char *agent,
                           int strength, const char *resource, int op, int scope,
                           const char *approved_by, const unsigned char *key, size_t keylen);
/* v2 variant: also binds session_id, project and dest_kind (sets grant_version
 * 2). session_id/project may be NULL/"" for "any". */
char *kai_grant_build_json2(const char *id, long long created, long long expires,
                            int pid, unsigned long long pidversion, const char *agent,
                            int strength, const char *resource, int op, int scope,
                            const char *approved_by, const char *session_id,
                            const char *project, int dest_kind,
                            const unsigned char *key, size_t keylen);

/* Load every *.json grant under dir (e.g. <home>/grants). Caller free()s *out.
 * A grant with a durable "<dir>/<id>.used" marker (a spent one-shot) is skipped. */
int kai_grants_load(const char *dir, kai_grant **out, int *n);
/* Has this grant id been durably consumed (a "<dir>/<id>.used" marker exists)? */
int kai_grant_is_consumed(const char *dir, const char *id);

/* Safe pause (M1.7): a wall paused for a bounded window with auto-resume. Read
 * off the reload path, never in the hot handler. wall is "storage"|"network". */
int kai_wall_paused(const char *wall, long long now);
int kai_wall_pause_write(const char *wall, long long minutes); /* <=0 clears */

/* Write a structured grant lifecycle audit record (source "grant"). Logs only
 * identifiers (id, resource path, agent, action, outcome, reason) -- never keys,
 * file contents, or credentials. A side effect; never gates a decision. action
 * is e.g. requested|approved|denied|used|expired|revoked|rejected. */
void kai_grant_audit(const char *action, const char *id, const char *agent,
                     const char *resource, int op, const char *outcome, const char *reason);

/* Index of a grant that authorizes (subject, resolved_path, op) at time `now`
 * with a valid HMAC, not expired, and identity bound (pid+pidversion+agent);
 * weak identities are eligible only for one-shot scope. Else -1. Resource match
 * is EXACT on the canonical path, so a symlink to another file cannot widen it. */
int kai_grant_match(const kai_grant *grants, int n, const kai_grant_subject *s,
                    const char *resolved_path, int op, long long now,
                    const unsigned char *key, size_t keylen);

/* The storage enforcement gate WITH grants. Returns 1 = allow, 0 = deny.
 * not-protected -> allow; un-exemptable (builtin/control) -> deny (no grant can
 * override); soft-protected with a matching valid grant -> allow; else deny.
 * Fills why with the matched rule (or "scoped grant" when a grant allowed it). */
int kai_storage_decide(const kai_policy *p, const char *resolved_path,
                       const char *cwd, int op, const kai_grant_subject *s,
                       const kai_grant *grants, int ngrants, long long now,
                       const unsigned char *key, size_t keylen,
                       char *why, size_t whylen);

/* realpath() wrapper (resolves symlinks) to canonicalize before store/match;
 * falls back to lexical normalize if realpath fails. 1 ok, 0 on error. */
int kai_grant_resolve(const char *path, char *buf, size_t buflen);

/* ---- Approval store (Scoped Approvals M2) ----
 * Thread-safe holder of the current policy + grant set, with bounded reload,
 * explicit generations, immediate revocation, and ATOMIC one-shot consumption.
 * The decision path takes a read lock; reload/revoke take a write lock. One-shot
 * grants are consumed by an atomic filesystem unlink, so under concurrency
 * exactly one caller can spend a given one-shot grant. Fail-closed: a grant dir
 * that can't be read yields zero grants (more denials); a policy that fails to
 * reload keeps the last good one (availability), never silently widening. */
typedef struct kai_approval_store kai_approval_store;

/* policy_path NULL = default location. key is the approval key (may be NULL/0
 * in tests with only unsigned grants, which then never match). debounce_sec
 * bounds how often reload actually re-stats the files. */
kai_approval_store *kai_approval_store_open(const char *policy_path, const char *grants_dir,
                                            const unsigned char *key, size_t keylen,
                                            long long debounce_sec);
void kai_approval_store_close(kai_approval_store *s);

/* Re-stat policy+grants (subject to debounce unless force) and atomically swap
 * the snapshot if changed. Returns 1 if a swap happened, else 0. */
int kai_approval_store_reload(kai_approval_store *s, int force);
/* Install the approval key after the store was opened policy-only. Call off the
 * authorization path; verifies and reloads grants under the store write lock.
 * Returns 1 when installed, 0 for an invalid/already installed key. */
int kai_approval_store_install_key(kai_approval_store *s,
                                   const unsigned char *key, size_t keylen);
unsigned long kai_approval_store_generation(const kai_approval_store *s);
int kai_approval_store_count(kai_approval_store *s); /* current grant count */

/* The decision, under a read lock. 1 = allow, 0 = deny. A matching one-shot
 * grant is consumed atomically here; if the consume loses a race, this denies. */
int kai_approval_store_decide(kai_approval_store *s, const char *resolved_path,
                              const char *cwd, int op, const kai_grant_subject *subj,
                              long long now, char *why, size_t whylen);

/* Revoke immediately against the running store (removes the file AND the
 * in-memory snapshot entry, bumping the generation). Returns number removed. */
int kai_approval_store_revoke(kai_approval_store *s, const char *id_prefix);

/* kai_path_protected over the store's CURRENT policy snapshot, under the read
 * lock. Lets a caller make the "is this protected / which rule" check against
 * the same coherent, reloaded snapshot the grant decision uses, instead of a
 * separately-loaded policy. Returns 1 protected (fills why), else 0. */
int kai_approval_store_protected(kai_approval_store *s, const char *path,
                                 const char *cwd, char *why, size_t whylen);

/* ---- Storage ES-handler profiler (dev/benchmark only; default OFF) ----
 * Lock-free, fixed-size, zero-allocation aggregation so it can be called from
 * the Endpoint Security authorization hot path without adding a lock, an
 * allocation, or blocking I/O. Stages name the work inside one auth callback;
 * KAI_PROF_DEADLINE records the ES deadline margin (headroom in ns) at the
 * moment Kai responds. Durations are nanoseconds. Not a user-facing feature. */
enum kai_prof_stage {
    KAI_PROF_TOTAL = 0,   /* whole authorization callback                 */
    KAI_PROF_CLASSIFY,    /* process classification (agent or not)        */
    KAI_PROF_PATH,        /* extracting path(s) from the ES event         */
    KAI_PROF_POLICY,      /* kai_path_protected evaluation                */
    KAI_PROF_RESPOND,     /* the es_respond_* call                        */
    KAI_PROF_DEADLINE,    /* ES auth deadline margin (headroom) at respond */
    KAI_PROF_NSTAGES
};
void   kai_prof_set_enabled(int on);          /* default 0; one relaxed flag  */
int    kai_prof_enabled(void);
void   kai_prof_record(int stage, uint64_t ns); /* no-op (one branch) if off  */
void   kai_prof_reset(void);
/* Serialize the aggregate (per stage: count, avg/p95/p99/max in microseconds)
 * as JSON into buf. Emits only timing numbers — never a path, a process name,
 * or any user datum — so it is safe to export without touching protected data.
 * Returns the full length the JSON needs (excluding the NUL); if that is >=
 * buflen the output was truncated, so retry with a larger buffer. */
size_t kai_prof_export_json(char *buf, size_t buflen);

/* ---- Agent identity ----
 * An agent is matched by executable path, any argv element, or code-signing
 * Team ID, using the policy's `agent` lines. */
int kai_agent_match(const kai_policy *p, const char *exe, const char *const *argv,
                    int argc, const char *team, char *name, size_t namelen);
/* Is pid an agent or a descendant of one? Walks the parent chain. Returns 1
 * and fills name (agent name) and agent_pid, else 0. */
int kai_process_agent(const kai_policy *p, int pid, char *name, size_t namelen,
                      int *agent_pid);

/* ---- AI gateway ----
 * Local HTTP server that cleans AI API requests and forwards them upstream.
 * Blocks until stopped. Point agents at it with ANTHROPIC_BASE_URL etc. */
int kai_gateway_run(const char *listen_addr, int port);

const char *kai_action_name(kai_action a);
void kai_report_summary(const kai_report *rep, char *out, size_t outlen);

/* Audit log: append one hash-chained record. Never pass secret values. */
int kai_audit(const char *source, const char *event, const char *decision,
              const char *rule, const char *detail);

/* A record with the context the activity view shows. Optional fields may be
 * NULL or "" and are then left out. target and match must already be
 * redacted (hooks pass them through the scanner first). */
#define KAI_AUDIT_TARGET_MAX 400
typedef struct {
    const char *source;   /* claude, cursor, codex, network, ...            */
    const char *event;    /* PreToolUse, beforeShellExecution, AfterBlock    */
    const char *decision; /* block | warn | log | redact | exempt | note     */
    const char *rule;
    const char *detail;   /* the reason, in words                           */
    const char *tool;     /* Bash, Read, Shell, ...                         */
    const char *target;   /* command, path or prompt excerpt (redacted)     */
    const char *match;    /* the part that matched (redacted)               */
    const char *session;  /* the agent's session / conversation id          */
    const char *cwd;
} kai_audit_entry;
int kai_audit_write(const kai_audit_entry *e);

/* ---- Denial records (M0: make failure visible) ----
 * A denial's `rule` field carries a REASON CODE from this controlled
 * vocabulary, never the destination/host (that goes in `target`). A matched
 * rule pattern goes in `match` ONLY when a rule actually matched. So a
 * not-on-allowlist drop no longer reads "rule: <host>" as if a rule matched. */
#define KAI_REASON_NOT_ALLOWLISTED "not_on_allowlist"   /* egress: absent from the allowlist */
#define KAI_REASON_RULE_DENIED     "rule_denied"        /* a configured rule matched (see match) */
#define KAI_REASON_PROTECTED       "protected_resource" /* storage: a protected path (see match) */
#define KAI_REASON_UNATTRIBUTED    "unattributed_process" /* identity could not be established */

/* Write a structured denial record. source "network"|"storage"; event = agent;
 * decision "block"|"would-block"|"log"; resource = host:port or path (-> target);
 * op -> tool; reason_code = one of KAI_REASON_*; matched_rule -> match (may be
 * NULL/"" when no rule matched); detail = the human sentence. Logs no secrets. */
void kai_denial_audit(const char *source, const char *agent, const char *decision,
                      const char *resource, const char *op, const char *reason_code,
                      const char *matched_rule, const char *detail);
/* Verify the chain. Returns 0 if intact; fills nlines and err. */
int kai_audit_verify(const char *path, int *nlines, char *err, size_t errlen);
const char *kai_home(void);       /* $KAI_HOME or ~/.kai */
const char *kai_audit_path(void); /* <home>/audit.log    */

#ifdef __cplusplus
}
#endif
#endif /* KAI_H */
