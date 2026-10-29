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
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KAI_VERSION "0.1.0"
/* MAJOR.MINOR.PATCH[-preview.N]; a pre-release is older than its release. */
int kai_version_cmp(const char *a, const char *b);

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
/* True if `rule` (the value kai_path_protected fills into `why`) is the
 * trust-store class: CA trust bundles (Homebrew ca-certificates, OpenSSL
 * cert bundles, certifi cacert), /etc/ssl, and keychain trust-settings files.
 * Agent READS are allowed (TLS verification needs them); WRITES are blocked but
 * carry the OVERRIDE tier (grant-overridable), since they change which websites
 * the Mac trusts. */
int kai_rule_is_trust_store(const char *rule);
/* Login persistence (~/Library/LaunchAgents, /Library/LaunchAgents,
 * /Library/LaunchDaemons): reads allowed, a write is Ask-level. */
int kai_rule_is_persistence(const char *rule);
/* A public, non-secret file inside a .ssh dir (known_hosts[.old], config, *.pub):
 * agents may READ these; private keys stay protected. 1 if it is one. */
int kai_ssh_public_file(const char *path);
/* A protect rule that matches by name only (*.key, *.pem, id_rsa, .env, …), not
 * a folder/path rule (~/.ssh, ~/.aws). 1 if name-only. */
int kai_rule_is_name_pattern(const char *rule);
/* Is `path` inside `agent`'s own working state (its dot-dir under home,
 * ~/.claude.json, $CODEX_HOME, Cursor's Application Support, ...)? 1 if so. */
int kai_agent_own_state(const char *agent, const char *path, const char *cwd);
/* Phase A item 1: 1 when `rule` (the protect match for `path`) is a blanket
 * name rule and `path` is in the requesting agent's own state, so the agent
 * may use it. Folder rules, builtin control paths and Kai's home: never. */
int kai_own_state_exempt(const kai_policy *p, const char *agent, const char *path,
                         const char *cwd, const char *rule);
/* kai_path_protected, minus the requesting agent's own state (agent may be NULL). */
int kai_path_protected_as(const kai_policy *p, const char *agent, const char *path,
                          const char *cwd, char *why, size_t whylen);
/* Creating a brand-new file whose NAME matches a secret pattern, outside any
 * protected folder, is not a secret access: 1 = allow (and log) this open. Only
 * when o_creat is set and the file does not already exist. */
int kai_new_secret_file(const kai_policy *p, const char *path, int o_creat);
/* Is `name` an agent product the storage and network walls recognize? (The
 * policy carries the built-in agent rules both walls classify by.) */
int kai_agent_wall_recognized(const kai_policy *p, const char *name);
/* Number of agent rules (built-ins + policy `agent` lines). */
int kai_policy_agent_count(const kai_policy *p);

/* Agent product kind, from the shipped catalog: how Kai finds its sessions. */
typedef enum {
    KAI_AGENT_CLI = 0,          /* one root process per terminal (Aider, Codex, …) */
    KAI_AGENT_IDE = 1,          /* an app hosting many chats/windows (Cursor, Zed, …) */
    KAI_AGENT_IDE_EXTENSION = 2,/* an agent inside an editor extension (Cline, Copilot) */
    KAI_AGENT_BROWSER = 3       /* a browser extension (Chrome AI chats) */
} kai_agent_kind;
int kai_agent_product_kind(const char *name);  /* kai_agent_kind; CLI if unknown */
int kai_agent_catalog_verified(const char *name); /* 1 only if checked vs an install */
int kai_agent_has_hooks(const char *name);     /* Kai has a hook integration for it */
const char *kai_agent_coverage_note(const char *name); /* card disclosure, or NULL */

/* ---- MCP tool identity + policy (Step 4) ----
 * An MCP tool call is a (server, tool) pair. Parse Claude Code's
 * "mcp__<server>__<tool>" naming; returns 1 and fills server/tool, 0 if the
 * name is not an MCP tool (then treat it as a normal tool call). */
int kai_mcp_parse_tool(const char *tool_name, char *server, size_t slen,
                       char *tool, size_t tlen);
/* Decide (server, tool) against the policy's `mcp` rules. Most-specific wins;
 * no rule = KAI_ACT_WARN (ask: a decision card). Server descriptions and
 * annotations (readOnlyHint, …) never reach here and never change this. */
kai_action kai_mcp_decide(const kai_policy *p, const char *server, const char *tool);
/* The host a server declares in .mcp.json (a proposal, never authority): lets
 * the approval card offer "also allow <host> for this session". 1 if found. */
int kai_mcp_declared_host(const char *server, const char *cwd, char *out, size_t n);
/* Read the approval key bytes; returns the length read (0 if unavailable). Only
 * the app and the walls may read the key - never kai running in an agent tree. */
size_t kai_approval_key_read(unsigned char *out, size_t cap);
/* The session a process belongs to, from the Kai pid->session map (walks the
 * ancestry). The control service uses this to stamp a request from the caller's
 * audit token, never a payload-supplied id. 1 if found. */
int kai_session_for_pid(int pid, unsigned long long live_pidv, char *out, size_t n);
/* Service side of an MCP call: derive the session from caller_pid, allow (rc 0)
 * if a session grant covers it, else stage a pending card (rc 10). Runs in the
 * app (the only reader of the approval key). */
int kai_mcp_request(int caller_pid, const char *server, const char *tool,
                    const char *host, int verify_signature, char *msg, size_t msglen);

/* How far the user may override Kai's protection of a matched resource. S4 acts
 * on these; the storage/network walls already make non-builtin protections
 * grant-overridable (= OVERRIDE/CONFIRM) and builtin ones not (= NEVER). */
typedef enum {
    KAI_TIER_CONFIRM = 1,    /* a protected path/host: one confirm in the card  */
    KAI_TIER_OVERRIDE = 2,   /* policy block, e.g. the trust store: confirm sheet */
    KAI_TIER_BREAKGLASS = 3, /* private keys / cloud credentials: authentication  */
    KAI_TIER_NEVER = 4       /* Kai's own control store: never overridable        */
} kai_override_tier_t;
/* The override tier for a matched protect rule (the `why` string). */
kai_override_tier_t kai_override_tier(const char *rule);
/* A short human explanation of a protected class for a decision card (e.g. the
 * trust store), or NULL when the rule needs no special wording. */
const char *kai_rule_explanation(const char *rule);
/* True if `path` is Kai's own control store: the policy file, a file under the
 * grants dir, or a file under the pending-policy dir. These must never be
 * writable by an agent-tree process, Kai-signed or not (the storage wall uses
 * this to withhold the Kai-signature exemption from a tagged `kai` process). */
int kai_path_is_control_store(const char *path);
/* The policy store (policy, grants, pending) - writable ONLY by the signed app
 * process in v1. Narrower than the control store: excludes the registry, which
 * the storage extension writes. */
int kai_path_is_policy_store(const char *path);
/* The approval key: only the app may read it (never agent-tree kai). */
int kai_path_is_approval_key(const char *path);

/* ---- policy and permission changes (v1) ----
 * The Kai app is the only writer, in-process (kai_policy_dispatch). The CLI
 * shows policy and permissions; for a change it prints "Change this in Kai"
 * and opens the matching Settings page (kai://settings/<page>). */
int kai_policy_dispatch(int argc, char **argv, int caller_is_agent);
const char *kai_settings_page_for(int argc, char **argv);
int kai_cli_change_in_kai(int argc, char **argv);
/* ---- Kai -> agent hints (Item 7): fixed catalog text, never generated ---- */
/* Hint text for a catalog key (git/ssh/scp/gh/aws/gcloud/npm/gpg/docker), or a
 * fallback. Always non-NULL. Phrased as "ask the user to run it", never the agent. */
const char *kai_hint_text(const char *key);
/* The hint key a shell command maps to by the program it runs, or NULL. */
const char *kai_hint_key_for_command(const char *cmd);

/* Identify an XPC caller from its audit token bytes (sizeof(audit_token_t)):
 * validates the signature (anchored to Apple) and fills Team ID, signing id and
 * pid. Returns 1 if valid. Lets the Swift service verify a caller without any
 * SecCode code of its own. */
int kai_audit_token_identity(const void *token, size_t toklen, char *team, size_t tlen,
                             char *signid, size_t slen, int *pid);
int  kai_policy_dispatch(int argc, char **argv, int caller_is_agent);
int  kai_grant_dispatch(int argc, char **argv, int caller_is_agent);
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

/* ---- Session registry (S1) ----
 * One record per agent session: created at the agent's ROOT exec (keyed on its
 * audit token / pidversion), inherited by descendants (tracked by the ES wall),
 * ended at root exit. Written only by Kai components, under the control store,
 * so an agent tree cannot create or alter one. Backed by one JSON file per
 * session under <home>/registry (file-based and encapsulated behind this API,
 * so the backend can change without touching callers). Authorization never
 * trusts an agent-reported id; a session is established only from what the ES
 * wall observes. */
#define KAI_SESSION_ID_MAX 40
#define KAI_SESSION_PROJ_MAX 1024
typedef struct {
    char id[KAI_SESSION_ID_MAX];
    char agent[32];
    char agent_version[32];
    int root_pid;
    unsigned long long root_pidversion;  /* audit-token pidversion: defeats pid reuse */
    long long started_utc;
    long long ended_utc;                 /* 0 while active                            */
    char project[KAI_SESSION_PROJ_MAX];  /* canonical working dir at root exec        */
    char host_app[64];                   /* Terminal, iTerm, Cursor, ...              */
    char tty[24];                        /* controlling terminal (window/tab), "" none */
    int child_count;                     /* processes under the root (scan sessions)   */
    int source;                          /* kai_session_source: how it was discovered  */
    int kind;                            /* kai_session_kind: session/background/orphan */
} kai_session;

/* How a session was discovered. ES is authoritative (storage wall active); SCAN
 * is the storage-wall-free process scan; both can be present and are merged. */
typedef enum { KAI_SESS_ES = 0, KAI_SESS_SCAN = 1 } kai_session_source;

/* What a discovered agent process actually is. Only SESSION is counted and
 * shown as a session; NESTED is folded into its parent session; BACKGROUND is
 * the agent's supervisor/daemon; ORPHAN is a stale no-tty process. */
typedef enum {
    KAI_KIND_SESSION = 0, KAI_KIND_NESTED = 1, KAI_KIND_BACKGROUND = 2, KAI_KIND_ORPHAN = 3
} kai_session_kind;

/* Pure classifier (testable with fixtures): decide what an agent process is from
 * its command line, whether it has a controlling tty, whether it reparented to
 * launchd, its age, and whether an ancestor is the SAME agent (nested). */
int kai_classify_session(const char *cmdline, int has_tty, int parent_is_launchd,
                         long long age_sec, int nested_in_same_agent);
const char *kai_session_kind_name(int kind);

/* Storage-wall-free session discovery (S-redesign item 1): scan running
 * processes for agent ROOT processes (by the policy's agent rules — code
 * signing / exe / arg), recording start time, working dir, host app and child
 * count. Works with no storage wall. Caller frees *out. */
int kai_sessions_scan(const kai_policy *p, kai_session **out, int *n);

/* The enforcement label for a session given which walls are observed active.
 * Never claims "protected" for a session no active wall can attribute. */
const char *kai_enforcement_label(int storage_active, int network_active);
/* A registry session is live: not ended, root process running and not a newer
 * process reusing its pid. */
int kai_session_live(const kai_session *s);
/* Session label from measured wall levels (>= 1 covers: Watch or Protect). */
const char *kai_enforcement_from_levels(int files, int internet);
/* Session activity: "working" = a command or hook in the last 15 minutes. */
#define KAI_WORKING_WINDOW 900
int kai_session_working(long long last_active, long long now);
const char *kai_session_activity_dir(void);
/* Record activity for a session (and the working folder it ran in). */
int kai_session_activity_touch(const char *sid, const char *workspace, long long now);
/* Last activity of a session, overall (workspace NULL) or in a folder (and below). 0 = never. */
long long kai_session_last_active(const char *sid, const char *workspace);
/* Remove registry records of "(delegated)" processes. Returns the count. */
int kai_sessions_prune_delegated(void);
/* The one status sentence ("Protected · 3 agents working", "Watching only",
 * "Files protection is off", ...). files/internet: 0 off, 1 watch, 2 protect;
 * internet -1 = not verified (left out of the headline); agents < 0 = unknown.
 * Writes into out and returns it. */
const char *kai_status_sentence(int files, int internet, int agents, int paused,
                                char *out, size_t n);
/* The Kai app group (Team-ID-prefixed; matches the entitlements). */
#define KAI_APP_GROUP "KD446VDTM2.io.github.sameehj.kai"
/* A wall's VERIFIED level from its root-owned heartbeat: 2 block, 1 log, 0 off,
 * -1 not verified. Never inferred from the policy. */
int kai_wall_observed_level(const char *wall);
/* B3: wall state words for Settings: not installed · off · starting ·
 * watching · protecting · unhealthy. */
enum { KAI_WALL_OS_NOT_INSTALLED = 0, KAI_WALL_OS_OFF = 1, KAI_WALL_OS_STARTING = 2,
       KAI_WALL_OS_ON = 3, KAI_WALL_OS_FAILED = 4 };
const char *kai_wall_state_word(int os, int level);
/* B4: the loaded policy's fingerprint (12 hex of SHA-256, or "built-in"); the
 * walls put it in their heartbeat so status can say whether they run the
 * current policy. */
void kai_policy_fingerprint(char *out, size_t n);
/* A field from a wall's verified heartbeat, as text. 1 found, else 0. */
int kai_heartbeat_field(const char *wall, const char *key, char *out, size_t n);
/* Verify one heartbeat file: owned by `owner`, not group/world-writable, fresh
 * (30 s), naming `wall`. Level as above, -1 if any check fails. */
int kai_heartbeat_level(const char *path, const char *wall, uid_t owner);
/* Pause as a visible state: NONE, PENDING (marker written, the wall hasn't
 * confirmed it - "Pausing…"), ACTIVE (marker + the wall's verified heartbeat
 * lists it). sid NULL = the global pause. */
enum { KAI_PAUSE_NONE = 0, KAI_PAUSE_PENDING = 1, KAI_PAUSE_ACTIVE = 2 };
int kai_pause_state(const char *sid, long long now);
/* One Kai: the release instance is /Applications/Kai.app signed by this team;
 * only it hosts the control service. */
#define KAI_RELEASE_TEAM "KD446VDTM2"
int kai_app_is_release(const char *bundle_path, const char *team);
/* May this Kai-signed process open the approval key? (exact signing id + Team
 * ID + location; the app r/w, the network extension read-only, nothing else) */
int kai_approval_key_access(const char *signing_id, const char *team, const char *exe, int write);
/* Exclusive single-instance lock; fd to keep open, or -1 (held / can't open). */
int kai_app_lock_acquire(const char *path);
/* Anything paused (Kai or any session)? For the menu-bar icon. */
int kai_any_pause_active(long long now);
int kai_pause_state_at(const char *heartbeat, uid_t owner, const char *sid, long long now);
/* Where the (sandboxed) network extension writes its heartbeat: the console
 * user's app-group container. */
const char *kai_network_heartbeat_path(void);

/* ---- Discovery (item 5) ---- */
typedef struct { char exe[1024]; char host[256]; long long last_utc; } kai_discovery;
int kai_host_is_model_api(const char *host);     /* anthropic/openai/google/openrouter/… */
/* 1 when an unrecognized process that contacted a model API also spawns shells
 * -> suggest protecting it. Kai NEVER auto-adds; this only drives a suggestion. */
int kai_looks_like_agent(int contacted_model_api, int spawns_shells, int already_recognized);
/* The network wall records a non-agent's model-API contact (keyed by exe). */
int kai_discovery_record(const char *exe, const char *host);
int kai_discovery_load(kai_discovery **out, int *n);   /* caller frees *out */
void kai_pid_exe(int pid, char *out, size_t n);        /* a pid's executable path */

/* ---- AI chats (item 3) ----
 * Browser AI chats (claude.ai, chatgpt.com, gemini, …) are not CLI agents and
 * the walls don't apply to them; Kai still SHOWS them so the user sees where AI
 * is used. The data comes only from the Kai browser extension over native
 * messaging (src/native.c) — the network wall stays agent-only and never
 * records a non-agent flow. Site only: no full URL, no chat text is stored.
 * Records live under <home>/chats, keyed by site. Visibility only. */
typedef struct {
    char site[256];      /* site only, e.g. "claude.ai" — never a full URL      */
    long long last_utc;  /* last time the extension reported this site          */
    int open_tabs;       /* tabs currently open on this site                    */
    int redactions;      /* redactions Kai applied before sending, on this site */
    int overrides;       /* times the user chose to send anyway                 */
} kai_chat;
int kai_host_is_ai_chat(const char *site);     /* claude.ai/chatgpt.com/gemini/… */
/* Record/update the browser extension's status for one chat site. */
int kai_chat_record(const char *site, int open_tabs, int redactions, int overrides);
int kai_chat_load(kai_chat **out, int *n);     /* caller frees *out */

/* Create or update a session record (idempotent on id). Returns 0 on success.
 * Called by Kai components only; the control store keeps agents out. */
int kai_session_begin(const kai_session *s);
/* Convenience for the ES wall: create a session record from plain C strings
 * (no Swift fixed-array copying). Returns 0 on success. */
int kai_session_record(const char *id, const char *agent, const char *agent_version,
                       int root_pid, unsigned long long root_pidversion,
                       const char *project, const char *host_app, long long started_utc);
/* Mark a session ended (root exit). Returns 0 if updated, -1 if unknown. */
int kai_session_end(const char *id, long long ended_utc);
/* Load all session records, newest-started first. Caller frees *out. */
int kai_sessions_load(kai_session **out, int *n);
/* Fill `out` for one session id. Returns 1 if found, 0 otherwise. */
int kai_session_get(const char *id, kai_session *out);
/* The registry directory: <home>/registry. */
const char *kai_session_dir(void);

/* Descriptive, agent-reported session data (S3), kept APART from the registry
 * so it never drives authorization. Record the session topic (e.g. the first
 * user prompt): it is redacted through `p` and truncated before storage. A
 * report binds only to an ES session id Kai observed; an agent session id
 * already bound to a different ES session is rejected and logged. Returns 0 on
 * success, -1 on reject. */
int kai_session_report_topic(const kai_policy *p, const char *es_session,
                             const char *agent_session, const char *raw_topic);
/* Read the stored (already redacted) topic for an ES session. 1 if present. */
int kai_session_report_get(const char *es_session, char *topic, size_t topiclen);
/* The reports directory: <home>/reports (written by the signed kai hook). */
const char *kai_session_reports_dir(void);

/* Per-session pause (S6): skip Kai for one session for a time-boxed window,
 * auto-resuming when it elapses. `minutes<=0` resumes. The caller consults
 * kai_session_paused only for SOFT-protected resources; never-tier (the control
 * store) still applies while paused. */
int kai_session_paused(const char *session, long long now);
/* The epoch a session's pause expires at, or 0 if not paused (for "Paused until"). */
long long kai_session_pause_until(const char *session);
int kai_session_pause_write(const char *session, long long minutes);

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
    int confirmed;              /* v3: user passed the override confirm sheet    */
    int authenticated;          /* v3: LocalAuthentication passed (break-glass)   */
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

/* v3: also signs the honor flags (S4). `confirmed` = the user passed the
 * override confirm sheet; `authenticated` = LocalAuthentication passed, for a
 * break-glass resource. The flags are in the signed canonical form, so an agent
 * cannot flip them on a signed grant to escalate its tier. */
char *kai_grant_build_json3(const char *id, long long created, long long expires,
                            int pid, unsigned long long pidversion, const char *agent,
                            int strength, const char *resource, int op, int scope,
                            const char *approved_by, const char *session_id,
                            const char *project, int dest_kind,
                            int confirmed, int authenticated,
                            const unsigned char *key, size_t keylen);
/* S4 tier enforcement: does this signed grant meet the resource's override
 * tier, and is its session still active? Both walls apply these before honoring
 * a matched grant. */
int kai_grant_satisfies_tier(const kai_grant *g, kai_override_tier_t tier);
int kai_grant_session_ended(const kai_grant *g);

/* ---- B2: persistent decisions ----
 * Keep blocked (no card again; still audited) and Allow rules (every future
 * session), bound to the VERIFIED agent identity ("<signing id> (<team>)" from
 * kai_pid_code_identity) and an exact destination. Signed with the approval
 * key; an Allow rule must carry owner authentication and a real hostname. */
enum { KAI_RULE_ALLOW = 1, KAI_RULE_KEEP_BLOCKED = 2 };
typedef struct {
    char id[40];
    int kind;
    char identity[160];
    char agent[64];
    char dest[KAI_GRANT_RES_MAX];
    int op;
    long long created_utc;
    long long expires_utc;      /* 0 = until removed; else a temporary allow */
    int authenticated;
    char hmac[65];
} kai_decision_rule;
const char *kai_rules_dir(void);          /* <kai home>/rules */
int kai_rule_dest_ok(int kind, const char *dest); /* no Allow rule for an IP */
char *kai_rule_build_json(const char *id, int kind, const char *identity, const char *agent,
                          const char *dest, int op, long long created, int authenticated,
                          const unsigned char *key, size_t keylen);
int kai_rule_from_json(const char *json, kai_decision_rule *out);
/* Fix 2: the same with an expiry. A temporary Allow (at most a day) needs no
 * owner authentication; it is for "Allow <agent> to reach <host> for 1 hour"
 * when there is no session to bind to. */
char *kai_rule_build_json_until(const char *id, int kind, const char *identity, const char *agent,
                                const char *dest, int op, long long created, long long expires,
                                int authenticated, const unsigned char *key, size_t keylen);
/* KAI_RULE_ALLOW, KAI_RULE_KEEP_BLOCKED (wins over an Allow) or 0. Only
 * verified rules count. dir NULL = kai_rules_dir(). */
int kai_rule_lookup(const char *dir, const char *identity, const char *dest, int op,
                    const unsigned char *key, size_t keylen, char *id_out, size_t idn);
/* Known telemetry/crash-report hosts (B2): denied silently, audited, one
 * passive hint per agent instead of a card. */
int kai_host_is_telemetry(const char *host);
/* Hosts in one agent's own profile (e.g. Cursor's sign-in), allowed for that
 * agent only. Each covers its subdomains. */
int kai_agent_profile_allows(const char *agent, const char *host);
/* The i-th profile host (0-based), for Settings: 1 while i is in range.
 * documented 0 = added from observed traffic, not the vendor's docs. */
int kai_agent_profile_host(int i, const char **agent, const char **host, int *documented);
/* Set env.<key>=<value> in Claude Code's settings (backup, atomic; refuses
 * invalid JSON with 3). The app calls it after owner authentication. */
int kai_claude_set_env(const char *key, const char *value);

/* ---- Preview 1 terminal rules (spec §5.3): kai allow / block / rules / undo ----
 * Read by the in-agent checks only (<kai home>/agent-rules.json). agent "*" =
 * every agent. An allow is exact and may expire (until 0 = no end); a block
 * covers subdomains and wins. */
enum { KAI_AGENT_RULE_ALLOW = 1, KAI_AGENT_RULE_BLOCK = 2 };
int kai_agent_rule_add(int kind, const char *agent, const char *host, long long until);
int kai_agent_rule_for(const char *agent, const char *host, long long now);
int kai_agent_rule_undo(void);                 /* 0 ok, -1 nothing to undo */
/* The hosts a shell command reaches (URLs, scp/rsync/ssh user@host:, nc host),
 * lowercased, without ports. Returns how many (at most max). */
int kai_command_hosts(const char *cmd, char hosts[][256], int max);
int kai_app_present(void);   /* the Kai app (with its OS walls) is installed */
int kai_claude_env_is(const char *key, const char *value);
/* The verified code-signing identity of a running process: "<signing id>
 * (<team>)", or "<signing id> (Apple)" for Apple's own. 1 when the signature
 * is valid (anchored to Apple), else 0 and out = "". */
int kai_pid_code_identity(int pid, char *out, size_t n);

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
/* Honor a session-bound MCP grant (resource "mcp:<server>/<tool>", or a
 * server-wide "mcp:<server>" + "/" + "*"): 1 if valid for this session (Step 4). */
int kai_mcp_grant_allows(const kai_grant *grants, int n, const char *session_id,
                         const char *server, const char *tool, long long now,
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
/* An extension's store: reads grants, never writes the grants folder. */
kai_approval_store *kai_approval_store_open_ro(const char *policy_path, const char *grants_dir,
                                               const unsigned char *key, size_t keylen,
                                               long long debounce_sec);
/* B1: may a Kai component (exact signing id; under_agent = runs in an agent's
 * tree) touch a path protected by `rule`? Kai's own state and agent hook
 * configs: yes. A path protected by the user's rules: only the kai CLI the
 * user runs (not under an agent). */
int kai_component_may_touch(const char *signing_id, int under_agent, const char *rule);
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
/* A network destination is allowed only by a matching, signed CONNECT grant. */
int kai_approval_store_decide_endpoint(kai_approval_store *s, const char *dest,
                                       const kai_grant_subject *subj, long long now,
                                       char *why, size_t whylen);
int kai_approval_store_own_state_exempt(kai_approval_store *s, const char *agent,
                                        const char *path, const char *cwd, const char *rule);
int kai_approval_store_protected(kai_approval_store *s, const char *path,
                                 const char *cwd, char *why, size_t whylen);
/* B2: the user's Keep blocked / Allow rule for (verified identity, dest, op),
 * read from the "rules" folder beside the grants folder and verified with the
 * store's key. KAI_RULE_ALLOW, KAI_RULE_KEEP_BLOCKED or 0. */
int kai_approval_store_rule(kai_approval_store *s, const char *identity, const char *dest, int op,
                            char *id_out, size_t idn);

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
/* The root of `agent`'s session that pid belongs to: the topmost process in
 * its ancestry (itself included) classified as that agent, as the session scan
 * reports it. 0 if none. */
int kai_agent_root_pid(const kai_policy *p, int pid, const char *agent);

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
    const char *identity; /* the agent's verified signing identity, if known */
} kai_audit_entry;
int kai_audit_write(const kai_audit_entry *e);
/* Today's (date NULL) or a given day's ("YYYY-MM-DD", local) counts of
 * meaningful records: secrets kept private and other blocks. Written with each
 * record, so it survives rotation and isn't limited to the app's buffer.
 * Returns 1 if the day has a counter file, else 0 (both counts 0). */
int kai_daily_counts(const char *date, int *secrets, int *other);

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
/* A denial that also names the Kai session and the agent's verified signing
 * identity, so Activity can offer "Allow for this session" or "Create a rule"
 * on the row later. Either may be NULL. */
void kai_denial_audit_ex(const char *source, const char *agent, const char *decision,
                         const char *resource, const char *op, const char *reason_code,
                         const char *matched_rule, const char *detail,
                         const char *session, const char *identity);
void kai_denial_audit(const char *source, const char *agent, const char *decision,
                      const char *resource, const char *op, const char *reason_code,
                      const char *matched_rule, const char *detail);
/* Verify the chain. Returns 0 if intact; fills nlines and err. */
int kai_audit_verify(const char *path, int *nlines, char *err, size_t errlen);
/* After a rotation: is audit.log.1 intact and does it end where the current
 * log says? 1 continues, 0 no rotation, -1 broken or missing (err says). */
int kai_audit_verify_rotation(char *err, size_t errlen);
/* A real hook call stamps <kai home>/hookseen/<agent>; when was it? 0 = never. */
void kai_hook_seen(const char *agent);
long long kai_hook_last_seen(const char *agent);
const char *kai_home(void);       /* $KAI_HOME or ~/.kai */
const char *kai_audit_path(void); /* <home>/audit.log    */

#ifdef __cplusplus
}
#endif
#endif /* KAI_H */
