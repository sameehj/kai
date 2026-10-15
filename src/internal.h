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
} kai_rule;

#define KAI_MAX_LIST 256

struct kai_policy {
    char source[512];
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
    int injection_on;
    size_t max_scan;
    /* network wall */
    kai_egress_mode egress_mode;
    char *egress_allow[KAI_MAX_LIST];
    int negress;
    /* agent identities: "exe", "arg" or "team" patterns */
    struct {
        char name[32];
        char kind[8];
        char *pattern;
    } agents[KAI_MAX_LIST];
    int nagents;
    int gateway_port;
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
void kai_proc_free(kai_proc *pr);

#endif
