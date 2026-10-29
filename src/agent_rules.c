/*
 * Kai — terminal rules for Preview 1 (experience spec §5.3).
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 *   kai allow <host> --agent <agent> [--for 1h|30m|1d | --always]
 *   kai block <host> [--agent <agent>]
 *   kai rules            what each agent can reach, and why
 *   kai undo             reverse the last change
 *
 * Preview 1 has no Kai app, so these write <kai home>/agent-rules.json, which
 * only the in-agent checks (hooks) read. Run from inside an agent's process
 * tree they refuse. With the Kai app installed they say "Change this in Kai":
 * the app's signed rules are the ones the OS walls trust. Honest limit:
 * without the Files wall, a program an agent runs could edit this file.
 */
#include "internal.h"
#include "kai.h"
#include "cJSON.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *rules_path(void) {
    static char buf[1200];
    snprintf(buf, sizeof buf, "%s/agent-rules.json", kai_home());
    return buf;
}
static const char *history_path(void) {
    static char buf[1200];
    snprintf(buf, sizeof buf, "%s/agent-rules.history", kai_home());
    return buf;
}

static cJSON *load_rules(void) {
    size_t n = 0;
    char *t = kai_read_file(rules_path(), 1 << 20, &n);
    cJSON *a = t ? cJSON_Parse(t) : NULL;
    free(t);
    if (!cJSON_IsArray(a)) { cJSON_Delete(a); a = cJSON_CreateArray(); }
    return a;
}

static int write_atomic(const char *path, const char *data) {
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    int ok = fputs(data, f) >= 0;
    ok = (fclose(f) == 0) && ok;
    chmod(tmp, 0600);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

/* Save the rules as they are now (one line per change) so undo can go back. */
static void push_history(void) {
    size_t n = 0;
    char *t = kai_read_file(rules_path(), 1 << 20, &n);
    cJSON *a = t ? cJSON_Parse(t) : NULL;
    free(t);
    char *line = cJSON_PrintUnformatted(cJSON_IsArray(a) ? a : NULL);
    cJSON_Delete(a);
    FILE *f = fopen(history_path(), "a");
    if (f) { fprintf(f, "%s\n", line ? line : "[]"); fclose(f); chmod(history_path(), 0600); }
    free(line);
}

static int save_rules(cJSON *a) {
    mkdir(kai_home(), 0700);
    char *s = cJSON_Print(a);
    int rc = s ? write_atomic(rules_path(), s) : -1;
    free(s);
    return rc;
}

static void lower(char *s) { for (; *s; s++) *s = (char)tolower((unsigned char)*s); }

int kai_agent_rule_add(int kind, const char *agent, const char *host, long long until) {
    if (!host || !*host || !agent || !*agent) return -1;
    char h[256];
    kai_strlcpy(h, host, sizeof h);
    lower(h);
    mkdir(kai_home(), 0700);
    push_history();
    cJSON *a = load_rules();
    /* one rule per agent + host: a new one replaces the old */
    for (int i = cJSON_GetArraySize(a) - 1; i >= 0; i--) {
        cJSON *r = cJSON_GetArrayItem(a, i);
        const char *ra = cJSON_GetStringValue(cJSON_GetObjectItem(r, "agent"));
        const char *rh = cJSON_GetStringValue(cJSON_GetObjectItem(r, "host"));
        if (ra && rh && !strcmp(ra, agent) && !strcmp(rh, h)) cJSON_DeleteItemFromArray(a, i);
    }
    cJSON *r = cJSON_CreateObject();
    cJSON_AddStringToObject(r, "kind", kind == KAI_AGENT_RULE_BLOCK ? "block" : "allow");
    cJSON_AddStringToObject(r, "agent", agent);
    cJSON_AddStringToObject(r, "host", h);
    cJSON_AddNumberToObject(r, "until", (double)until);
    cJSON_AddNumberToObject(r, "created", (double)time(NULL));
    cJSON_AddItemToArray(a, r);
    int rc = save_rules(a);
    cJSON_Delete(a);
    return rc;
}

int kai_agent_rule_undo(void) {
    size_t n = 0;
    char *t = kai_read_file(history_path(), 8u << 20, &n);
    if (!t || !n) { free(t); return -1; }
    while (n && t[n - 1] == '\n') t[--n] = '\0';
    char *last = strrchr(t, '\n');
    char *prev = last ? last + 1 : t;
    cJSON *a = cJSON_Parse(prev);
    int rc = cJSON_IsArray(a) ? save_rules(a) : -1;
    cJSON_Delete(a);
    if (rc == 0) {
        if (last) { last[1] = '\0'; rc = write_atomic(history_path(), t); }
        else unlink(history_path());
    }
    free(t);
    return rc;
}

/* An allow is exact; a block also covers subdomains. */
static int host_covers(const char *rule, const char *host, int subdomains) {
    size_t rl = strlen(rule), hl = strlen(host);
    if (rl == hl) return !strcasecmp(rule, host);
    return subdomains && hl > rl && host[hl - rl - 1] == '.' && !strcasecmp(host + hl - rl, rule);
}

int kai_agent_rule_for(const char *agent, const char *host, long long now) {
    if (!agent || !host || !*host) return 0;
    cJSON *a = load_rules();
    int found = 0;
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        const char *k = cJSON_GetStringValue(cJSON_GetObjectItem(r, "kind"));
        const char *ra = cJSON_GetStringValue(cJSON_GetObjectItem(r, "agent"));
        const char *rh = cJSON_GetStringValue(cJSON_GetObjectItem(r, "host"));
        double until = cJSON_GetNumberValue(cJSON_GetObjectItem(r, "until"));
        if (!k || !ra || !rh) continue;
        if (strcmp(ra, "*") && strcmp(ra, agent)) continue;
        if (until > 0 && (long long)until <= now) continue;
        int block = !strcmp(k, "block");
        if (!host_covers(rh, host, block)) continue;
        if (block) { found = KAI_AGENT_RULE_BLOCK; break; }   /* a block wins */
        found = KAI_AGENT_RULE_ALLOW;
    }
    cJSON_Delete(a);
    return found;
}

/* ---- the hosts a shell command reaches ---- */

static int add_host(char hosts[][256], int n, int max, const char *s, size_t len) {
    if (!len || len >= 256 || n >= max) return n;
    char h[256];
    memcpy(h, s, len); h[len] = '\0';
    lower(h);
    if (!strchr(h, '.') && strcmp(h, "localhost") != 0) return n;   /* not a host name */
    for (int i = 0; i < n; i++) if (!strcmp(hosts[i], h)) return n;
    kai_strlcpy(hosts[n], h, 256);
    return n + 1;
}

static int hostch(char c) { return isalnum((unsigned char)c) || c == '.' || c == '-'; }

typedef struct { char (*hosts)[256]; int n, max; } host_acc;

static void walk_hosts(char **argv, int argc, void *ud) {
    host_acc *acc = ud;
    int i = kai_shell_command_start(argv, argc);
    if (i >= argc) return;
    const char *b = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
    int netcat = !strcmp(b, "nc") || !strcmp(b, "ncat") || !strcmp(b, "netcat") || !strcmp(b, "telnet");
    int remote = !strcmp(b, "scp") || !strcmp(b, "rsync") || !strcmp(b, "ssh") || !strcmp(b, "sftp");
    int netcat_done = 0;
    for (int k = i + 1; k < argc; k++) {
        const char *a = argv[k];
        const char *u = strstr(a, "://");
        if (u) {
            const char *h = u + 3;
            const char *at = strpbrk(h, "@/");
            if (at && *at == '@') h = at + 1;          /* user:pass@host */
            size_t l = 0;
            while (hostch(h[l])) l++;
            acc->n = add_host(acc->hosts, acc->n, acc->max, h, l);
            continue;
        }
        if (remote && a[0] != '-') {                   /* [user@]host:path or user@host */
            const char *h = strchr(a, '@') ? strchr(a, '@') + 1 : a;
            size_t l = 0;
            while (hostch(h[l])) l++;
            if (l && (h[l] == ':' || (h[l] == '\0' && strchr(a, '@'))))
                acc->n = add_host(acc->hosts, acc->n, acc->max, h, l);
            continue;
        }
        if (netcat && !netcat_done && a[0] != '-') {   /* nc [opts] host port */
            size_t l = 0;
            while (hostch(a[l])) l++;
            if (l && a[l] == '\0') { acc->n = add_host(acc->hosts, acc->n, acc->max, a, l); netcat_done = 1; }
        }
    }
}

int kai_command_hosts(const char *cmd, char hosts[][256], int max) {
    if (!cmd || max <= 0) return 0;
    host_acc acc = {hosts, 0, max};
    kai_shell_walk(cmd, walk_hosts, NULL, &acc);
    return acc.n;
}

/* ---- the commands ---- */

int kai_app_present(void);
int kai_app_present(void) {
    const char *e = getenv("KAI_NO_APP");
    if (e && *e == '1') return 0;
    struct stat st;
    return stat("/Applications/Kai.app/Contents/Library/SystemExtensions", &st) == 0;
}

static int under_agent(void) {
    const char *t = getenv("KAI_TEST_AS_AGENT");   /* can only make it stricter */
    if (t && *t == '1') return 1;
#ifdef KAI_TEST_DIRECT_POLICY
    return 0;   /* test-only binary (tests/cli/kai-test): the suite runs inside an agent */
#endif
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;
    char name[64]; int apid;
    int hit = kai_process_agent(p, (int)getpid(), name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}

static const char *agent_title(const char *a) {
    if (!strcmp(a, "claude")) return "Claude Code";
    if (!strcmp(a, "codex")) return "Codex";
    if (!strcmp(a, "cursor")) return "Cursor";
    if (!strcmp(a, "*")) return "every agent";
    return a;
}

static long long parse_for(const char *s) {
    char *end = NULL;
    long long v = strtoll(s, &end, 10);
    if (v <= 0 || !end) return -1;
    if (!strcmp(end, "m")) return v * 60;
    if (!strcmp(end, "h")) return v * 3600;
    if (!strcmp(end, "d")) return v * 86400;
    return -1;
}

static int gatekeep(const char *verb) {
    if (under_agent()) {
        fprintf(stderr, "kai %s: refused. Run this in your own terminal, not from an agent.\n", verb);
        return 3;
    }
    if (kai_app_present()) {
        fprintf(stderr, "Change this in Kai: click a blocked item in Kai's Activity (or its card) to allow or "
                        "keep it blocked.\n(With the Kai app, the app keeps the rules, so Files and Internet "
                        "protection follow them too.)\n");
        return 4;
    }
    return 0;
}

static int cmd_rule(int kind, int argc, char **argv) {
    const char *verb = kind == KAI_AGENT_RULE_BLOCK ? "block" : "allow";
    const char *host = NULL, *agent = NULL;
    long long secs = kind == KAI_AGENT_RULE_ALLOW ? 3600 : 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--agent") && i + 1 < argc) agent = argv[++i];
        else if (!strcmp(argv[i], "--for") && i + 1 < argc) {
            if ((secs = parse_for(argv[++i])) < 0) { fprintf(stderr, "kai %s: --for takes 30m, 1h or 1d\n", verb); return 2; }
        } else if (!strcmp(argv[i], "--always")) secs = 0;
        else if (argv[i][0] != '-' && !host) host = argv[i];
        else { fprintf(stderr, "kai %s: unknown option %s\n", verb, argv[i]); return 2; }
    }
    if (!host) {
        fprintf(stderr, kind == KAI_AGENT_RULE_ALLOW
                ? "usage: kai allow <host> --agent claude|codex|cursor [--for 1h | --always]\n"
                : "usage: kai block <host> [--agent claude|codex|cursor]\n");
        return 2;
    }
    if (kind == KAI_AGENT_RULE_ALLOW && !agent) {
        fprintf(stderr, "kai allow: say which agent: --agent claude, --agent codex or --agent cursor\n");
        return 2;
    }
    if (!agent) agent = "*";
    int g = gatekeep(verb);
    if (g) return g;
    long long until = secs ? (long long)time(NULL) + secs : 0;
    if (kai_agent_rule_add(kind, agent, host, until) != 0) { fprintf(stderr, "kai %s: couldn't save the rule\n", verb); return 1; }
    char detail[600];
    snprintf(detail, sizeof detail, "kai %s %s for %s%s", verb, host, agent, until ? " (time-boxed)" : "");
    kai_audit("kai", verb, "note", "terminal_rule", detail);
    if (kind == KAI_AGENT_RULE_ALLOW) {
        char when[64] = "until you remove it (kai undo, or kai block)";
        if (until) {
            time_t t = (time_t)until; struct tm tmv; localtime_r(&t, &tmv);
            strftime(when, sizeof when, "until %H:%M", &tmv);
        }
        printf("Allowed %s to reach %s %s.\n", agent_title(agent), host, when);
    } else {
        printf("Blocked %s from reaching %s (and its subdomains).\n", agent_title(agent), host);
    }
    printf("Undo: kai undo\n");
    return 0;
}

int kai_cmd_allow(int argc, char **argv) { return cmd_rule(KAI_AGENT_RULE_ALLOW, argc, argv); }
int kai_cmd_block(int argc, char **argv) { return cmd_rule(KAI_AGENT_RULE_BLOCK, argc, argv); }

int kai_cmd_undo(int argc, char **argv) {
    (void)argc; (void)argv;
    int g = gatekeep("undo");
    if (g) return g;
    if (kai_agent_rule_undo() != 0) { printf("Nothing to undo.\n"); return 1; }
    kai_audit("kai", "undo", "note", "terminal_rule", "kai undo: last rule change reversed");
    printf("Undone: the rules are back to before your last change. See them: kai rules\n");
    return 0;
}

int kai_cmd_rules(int argc, char **argv) {
    (void)argc; (void)argv;
    cJSON *a = load_rules();
    long long now = (long long)time(NULL);
    int shown = 0;
    printf("What your agents can reach (rules you made with kai allow / kai block)\n");
    cJSON *r;
    cJSON_ArrayForEach(r, a) {
        const char *k = cJSON_GetStringValue(cJSON_GetObjectItem(r, "kind"));
        const char *ra = cJSON_GetStringValue(cJSON_GetObjectItem(r, "agent"));
        const char *rh = cJSON_GetStringValue(cJSON_GetObjectItem(r, "host"));
        long long until = (long long)cJSON_GetNumberValue(cJSON_GetObjectItem(r, "until"));
        if (!k || !ra || !rh || (until > 0 && until <= now)) continue;
        char when[48] = "";
        if (until) { time_t t = (time_t)until; struct tm tmv; localtime_r(&t, &tmv);
                     strftime(when, sizeof when, " until %H:%M", &tmv); }
        printf("  %-8s %-14s %s%s\n", !strcmp(k, "block") ? "blocked" : "allowed", agent_title(ra), rh,
               !strcmp(k, "block") ? " (and subdomains)" : when);
        shown++;
    }
    if (!shown) printf("  none yet. Everything else follows your policy (kai policy show).\n");
    printf("These are read by Kai's checks inside each agent. Without OS protection (Files), a program "
           "an agent runs could edit them.\n");
    cJSON_Delete(a);
    return 0;
}
