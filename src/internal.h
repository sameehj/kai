/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#ifndef KAI_INTERNAL_H
#define KAI_INTERNAL_H

#include "kai.h"
#include <regex.h>
#include <stdarg.h>
#include <stdio.h>

/* ---- growable string buffer ---- */
typedef struct {
    char *p;
    size_t len, cap;
    int oom;
} sb_t;

void sb_init(sb_t *b);
void sb_add(sb_t *b, const char *s, size_t n);
void sb_adds(sb_t *b, const char *s);
void sb_addf(sb_t *b, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
    ;
char *sb_take(sb_t *b); /* returns owned string ("" if empty), resets b */
void sb_free(sb_t *b);

/* ---- small helpers ---- */
char *kai_read_stream(FILE *f, size_t max, size_t *outlen);
char *kai_read_file(const char *path, size_t max, size_t *outlen);
char *kai_expand_home(const char *path); /* ~ and $HOME; caller frees */
char *kai_normalize_path(const char *path, const char *cwd); /* absolute, no . / .. */
void kai_strlcpy(char *dst, const char *src, size_t n);
const char *kai_exe_path(void);
const char *kai_policy_file(void); /* $KAI_POLICY or <kai home>/policy */
/* Browser extension (browser.c, native.c) */
#define KAI_NATIVE_HOST "io.github.sameehj.kai"
#define KAI_EXTENSION_ID "bfefkchkkleigcefbgligmkknhmdnhee" /* unpacked: manifest "key" */
/* The Chrome Web Store gives the published extension its own ID (shown in the
 * developer dashboard after the first upload). Put it here so Kai's helper
 * also answers the store-installed extension. Empty = not published yet. */
#ifndef KAI_STORE_EXTENSION_ID /* set at build time: make KAI_STORE_ID=<32 letters a-p> */
#define KAI_STORE_EXTENSION_ID ""
#endif
int kai_cmd_demo(int argc, char **argv);
int kai_cmd_allow(int argc, char **argv);
int kai_cmd_allow_file(int argc, char **argv);
int kai_cmd_allow_fetch(int argc, char **argv);
int kai_cmd_allow_mcp(int argc, char **argv);
int kai_cmd_allow_upload(int argc, char **argv);
int kai_cmd_block(int argc, char **argv);
int kai_cmd_rules(int argc, char **argv);
int kai_cmd_undo(int argc, char **argv);
int kai_browser_install(const char *exe);
int kai_browser_uninstall(void);
int kai_browser_installed(int *detected);
const char *kai_browser_ext_dir(void);
int kai_browser_extension_loaded(void);
int kai_native_host(const char *origin);

char *kai_codex_home(void);       /* $CODEX_HOME or ~/.codex; caller frees */
char *kai_codex_hooks_path(void); /* <codex home>/hooks.json; caller frees */

/* ---- policy internals ---- */
typedef enum { RULE_CONTENT = 0, RULE_INJECTION, RULE_UPLOAD } rule_kind;

typedef struct {
    char name[KAI_NAME_MAX];
    kai_action action;
    char *replacement; /* for KAI_ACT_REPLACE */
    regex_t re;
    int compiled;
    /* optional second check on a match; returns 0 to ignore it */
    int (*validate)(const char *match, size_t len);
} kai_rule;

/* Shell command reader (shell.c): calls on_cmd for every simple command
 * (quotes resolved, $(), ``, sh -c and eval included) and on_text for
 * heredoc bodies that don't feed a shell. Nothing is executed. */
typedef void (*kai_shell_cmd_fn)(char **argv, int argc, void *ud);
typedef void (*kai_shell_text_fn)(const char *text, void *ud);
void kai_shell_walk(const char *cmd, kai_shell_cmd_fn on_cmd, kai_shell_text_fn on_text, void *ud);
/* Index of the command actually run, past VAR=value and sudo/env/nohup/...
 * wrappers; argc if there is none. */
int kai_shell_command_start(char **argv, int argc);
/* One line per pipeline: "name args | name args" (see shell.c). Caller frees. */
char *kai_shell_view(const char *cmd);

/* A check can skip a rule the user made an exception for: return 1 to skip. */
typedef int (*kai_skip_fn)(const char *rule, void *ud);
/* kai_command_touches_protected / kai_command_looks_like_upload, skipping
 * rules skip() says are exempt, and (upload) copying the matched text. */
int kai_command_touches_protected_skip(const kai_policy *p, const char *cmd, const char *cwd,
                                       char *why, size_t whylen, kai_skip_fn skip, void *ud);
/* ... as seen by `agent` (NULL = any): its own state is exempt from name rules. */
int kai_command_touches_protected_as(const kai_policy *p, const char *agent, const char *cmd,
                                     const char *cwd, char *why, size_t whylen,
                                     kai_skip_fn skip, void *ud);
int kai_upload_match(const kai_policy *p, const char *cmd, char *why, size_t whylen,
                     char *match, size_t matchlen, kai_skip_fn skip, void *ud);
/* For the activity log: every rule match hidden, whatever its action (scan
 * leaves block/warn matches in place). NULL when secret detection is off,
 * because then nothing can be safely redacted. Caller frees. */
void kai_audit_suppress(int on);
int kai_policy_file_secret_ask(const kai_policy *p);
int kai_policy_upload_ask(const kai_policy *p);

/* Live health of an integration (src/health.c). ok=1: protection works now.
 * ok=0 with problem "": not installed. ok=0 with problem: installed, broken. */
typedef struct {
    int ok;
    char problem[300];
} kai_health;
void kai_health_agent(const char *agent, const char *config, kai_health *h);
void kai_health_chrome(const char *exe, kai_health *h);
char *kai_browser_host_exe(void); /* program the browser starts as Kai's helper */
char *kai_redact_for_log(const kai_policy *p, const char *text);
/* Kai's own protection (its settings, the agents' hook files): never exempt. */
int kai_rule_is_builtin(const char *rule);
/* Has the user made an exception ("exempt <rule> <glob>") covering target? */
int kai_policy_exempt(const kai_policy *p, const char *rule, const char *target);
int kai_policy_audit_context(const kai_policy *p); /* store redacted excerpts? */

/* validator for "password = …"-style matches (scan.c) */
int kai_plausible_secret_value(const char *match, size_t len);
/* validator for explicit "password: …" fields: any non-placeholder value */
int kai_plausible_password_value(const char *match, size_t len);

#define KAI_MAX_LIST 256

struct kai_policy {
    char source[512];
    int nunknown;             /* directives this version doesn't know (A.6b) */
    char unknown_first[64];
    kai_rule *rules;
    int nrules, caprules; /* content rules, in order */
    kai_rule *inj;
    int ninj, capinj; /* prompt-injection patterns */
    kai_rule *upl;
    int nupl, capupl; /* upload / remote-code patterns */
    char *protect[KAI_MAX_LIST];
    int nprotect; /* expanded patterns */
    char *allow[KAI_MAX_LIST];
    int nallow;
    kai_action builtin_secrets;
    kai_action prompt_action;
    kai_action file_secret_action;
    kai_action upload_action;
    int file_secret_ask; /* "ask": the agent asks the user (Claude Code), else block */
    int upload_ask;
    int fetch_block;     /* on_fetch block: the fetch tool needs a kai allow-fetch */
    int injection_on;
    size_t max_scan;
    /* network wall */
    kai_egress_mode egress_mode;
    char *egress_allow[KAI_MAX_LIST];
    int negress;
    char *channels[KAI_MAX_LIST];   /* "<agent>/<channel>", agent may be "*" */
    int nchannels;
    /* storage wall */
    kai_storage_mode storage_mode;
    /* agent identities: "exe", "arg" or "team" patterns */
    struct {
        char name[32];
        char kind[8];
        char *pattern;
    } agents[KAI_MAX_LIST];
    int nagents;
    /* MCP tool policy: server + tool ("*" = any tool on that server) -> action.
     * Matched most-specific first; no match = ask (a decision card). */
    struct {
        char server[64];
        char tool[64];
        kai_action action;
    } mcp[KAI_MAX_LIST];
    int nmcp;
    int gateway_port;
    /* the user's exceptions: rule name + glob over the command */
    struct {
        char rule[KAI_NAME_MAX];
        char *pattern;
    } exempt[KAI_MAX_LIST];
    int nexempt;
    int audit_context;
};

/* ---- process inspection (proc.c) ---- */
typedef struct {
    int pid, ppid;
    char exe[1024];
    char team[32];  /* code-signing Team ID, "" if unsigned / unknown */
    char **argv;    /* owned */
    int argc;
} kai_proc;
int kai_proc_read(int pid, kai_proc *out); /* 0 on success */
int kai_proc_read_fast(int pid, kai_proc *out); /* like kai_proc_read but skips the Team ID (no code-signing lookup) */
void kai_proc_free(kai_proc *pr);

/* Agent Control: live interactive sessions working now (a command or hook in
 * the last 15 minutes). The one count for the popover and `kai status`. */
int kai_sessions_working_count(void);

#endif
