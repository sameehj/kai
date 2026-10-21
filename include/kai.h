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
/* Verify the chain. Returns 0 if intact; fills nlines and err. */
int kai_audit_verify(const char *path, int *nlines, char *err, size_t errlen);
const char *kai_home(void);       /* $KAI_HOME or ~/.kai */
const char *kai_audit_path(void); /* <home>/audit.log    */

#ifdef __cplusplus
}
#endif
#endif /* KAI_H */
