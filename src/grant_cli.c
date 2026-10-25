/*
 * Kai — `kai grant` CLI (Scoped Approvals M1).
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * list / revoke / create for grant records under <home>/grants.
 *
 * SECURITY NOTE: `kai grant create` writes an UNSIGNED record (approved_by
 * "cli", empty HMAC). The enforcement engine (kai_storage_decide) only honors a
 * grant whose HMAC verifies under the approval key, and that key is held by the
 * menu-bar app and written only on a real human click. So a CLI-created grant
 * -- including one an agent manages to run -- is NOT honored until the app signs
 * it. create is for staging/inspection and tests, not for self-approval.
 */
#include "internal.h"
#include "kai.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void grants_dir(char *buf, size_t n) { snprintf(buf, n, "%s/grants", kai_home()); }

/* M1.3: an agent-attributed process must never create or revoke grants. Best-
 * effort: if our own process tree traces to a known agent, refuse. (A human
 * terminal has no agent ancestor.) */
static int caller_is_agent(void) {
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;                     /* can't determine: don't block the human */
    char name[64]; int apid;
    int hit = kai_process_agent(p, (int)getpid(), name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}
static int refuse_if_agent(const char *verb) {
    if (caller_is_agent()) {
        fprintf(stderr, "kai grant %s: refused -- an agent-attributed process may request "
                        "(write an unsigned record) but never create or revoke grants.\n", verb);
        return 1;
    }
    return 0;
}

static const char *op_name(int op) {
    return op == KAI_OP_WRITE ? "write" : op == KAI_OP_CONNECT ? "connect" : "read";
}
static const char *scope_name(int s) { return s == KAI_GRANT_ONESHOT ? "oneshot" : "process"; }
static int parse_op(const char *s) {
    if (!strcmp(s, "write")) return KAI_OP_WRITE;
    if (!strcmp(s, "connect")) return KAI_OP_CONNECT;
    if (!strcmp(s, "read")) return KAI_OP_READ;
    return -1;
}

/* List grants, optionally only those bound to `session` (NULL = all). */
static int grant_list(int json, const char *session) {
    char dir[512]; grants_dir(dir, sizeof dir);
    kai_grant *g = NULL; int n = 0;
    kai_grants_load(dir, &g, &n);
    long long now = (long long)time(NULL);
    int shown = 0;
    if (json) {
        printf("[");
        for (int i = 0; i < n; i++) {
            if (session && strcmp(g[i].session_id, session) != 0) continue;
            char *js = kai_grant_to_json(&g[i]);
            printf("%s%s", shown++ ? "," : "", js ? js : "null");
            free(js);
        }
        printf("]\n");
    } else {
        printf("%-22s %-8s %-7s %-7s %-9s %-8s %s\n",
               "id", "agent", "op", "scope", "expires", "signed", "resource");
        for (int i = 0; i < n; i++) {
            if (session && strcmp(g[i].session_id, session) != 0) continue;
            long long left = g[i].expires_utc - now;
            char exp[32];
            if (g[i].expires_utc == 0) snprintf(exp, sizeof exp, "never");
            else if (left <= 0) snprintf(exp, sizeof exp, "EXPIRED");
            else snprintf(exp, sizeof exp, "%llds", left);
            printf("%-22s %-8s %-7s %-7s %-9s %-8s %s\n",
                   g[i].id, g[i].agent, op_name(g[i].op), scope_name(g[i].scope),
                   exp, g[i].hmac[0] ? "yes" : "no", g[i].resource);
            shown++;
        }
        if (shown == 0) printf("(no grants%s)\n", session ? " for that session" : "");
    }
    free(g);
    return 0;
}

static int grant_revoke(const char *idprefix) {
    if (!idprefix || !*idprefix) { fprintf(stderr, "usage: kai grant revoke <id>\n"); return 2; }
    if (refuse_if_agent("revoke")) return 3;
    char dir[512]; grants_dir(dir, sizeof dir);
    kai_grant *g = NULL; int n = 0;
    kai_grants_load(dir, &g, &n);
    int removed = 0;
    size_t pl = strlen(idprefix);
    for (int i = 0; i < n; i++) {
        if (strncmp(g[i].id, idprefix, pl) == 0) {
            char fp[640];
            snprintf(fp, sizeof fp, "%s/%s.json", dir, g[i].id);
            if (unlink(fp) == 0) { printf("revoked %s\n", g[i].id); removed++; }
            else fprintf(stderr, "kai grant: could not remove %s\n", fp);
        }
    }
    free(g);
    if (!removed) { fprintf(stderr, "kai grant: no grant matching '%s'\n", idprefix); return 1; }
    return 0;
}

static int grant_create(int argc, char **argv) {
    if (refuse_if_agent("create")) return 3;
    kai_grant g;
    memset(&g, 0, sizeof g);
    g.op = KAI_OP_READ; g.scope = KAI_GRANT_PROCESS; g.strength = KAI_ID_STRONG;
    long long ttl = 300; /* 5 min default */
    const char *resource = NULL;
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i], *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--resource") && v) { resource = v; i++; }
        else if (!strcmp(a, "--op") && v) { g.op = parse_op(v); i++; }
        else if (!strcmp(a, "--pid") && v) { g.pid = atoi(v); i++; }
        else if (!strcmp(a, "--pidversion") && v) { g.pidversion = strtoull(v, NULL, 10); i++; }
        else if (!strcmp(a, "--agent") && v) { kai_strlcpy(g.agent, v, sizeof g.agent); i++; }
        else if (!strcmp(a, "--ttl") && v) { ttl = strtoll(v, NULL, 10); i++; }
        else if (!strcmp(a, "--scope") && v) { g.scope = strcmp(v, "oneshot") ? KAI_GRANT_PROCESS : KAI_GRANT_ONESHOT; i++; }
        else if (!strcmp(a, "--strength") && v) {
            g.strength = !strcmp(v, "strong") ? KAI_ID_STRONG : !strcmp(v, "medium") ? KAI_ID_MEDIUM : KAI_ID_WEAK; i++;
        } else { fprintf(stderr, "kai grant create: unknown arg '%s'\n", a); return 2; }
    }
    if (!resource || g.op < 0 || g.pid <= 0) {
        fprintf(stderr, "usage: kai grant create --resource <path> --pid <n> "
                        "[--pidversion n] [--agent name] [--op read|write|connect] "
                        "[--scope process|oneshot] [--strength weak|medium|strong] "
                        "[--ttl seconds]\n");
        return 2;
    }
    char resolved[KAI_GRANT_RES_MAX];
    if (!kai_grant_resolve(resource, resolved, sizeof resolved)) {
        fprintf(stderr, "kai grant create: cannot resolve resource path\n"); return 1;
    }
    kai_strlcpy(g.resource, resolved, sizeof g.resource);
    long long now = (long long)time(NULL);
    g.created_utc = now;
    g.expires_utc = ttl > 0 ? now + ttl : 0;
    snprintf(g.id, sizeof g.id, "g-%llx-%x", (unsigned long long)now, (unsigned)getpid());
    kai_strlcpy(g.approved_by, "cli", sizeof g.approved_by);
    g.hmac[0] = '\0'; /* UNSIGNED: the app signs on a real human approval */

    char dir[512]; grants_dir(dir, sizeof dir);
    mkdir(kai_home(), 0700);
    mkdir(dir, 0700);
    char fp[640];
    snprintf(fp, sizeof fp, "%s/%s.json", dir, g.id);
    char *js = kai_grant_to_json(&g);
    if (!js) { fprintf(stderr, "kai grant: serialize failed\n"); return 1; }
    FILE *f = fopen(fp, "w");
    if (!f) { fprintf(stderr, "kai grant: cannot write %s\n", fp); free(js); return 1; }
    fputs(js, f); fclose(f); free(js);
    printf("created %s (%s %s, %s, ttl %llds)\n", g.id, op_name(g.op),
           g.resource, scope_name(g.scope), ttl);
    printf("NOTE: this grant is UNSIGNED and will NOT be enforced until the Kai "
           "app signs it on your approval.\n");
    return 0;
}

/* kai pause <storage|network|all> <minutes> ; kai resume <...> (M1.7). Refuses
 * agent callers, like grant changes. */
int kai_cmd_pause(int argc, char **argv) {
    if (refuse_if_agent("pause")) return 3;
    if (argc < 1) { fprintf(stderr, "usage: kai pause <storage|network|all> <minutes>\n"); return 2; }
    long long mins = (argc >= 2) ? strtoll(argv[1], NULL, 10) : 15;
    const char *wall = argv[0];
    const char *walls[] = { "storage", "network" };
    for (int i = 0; i < 2; i++)
        if (!strcmp(wall, "all") || !strcmp(wall, walls[i]))
            kai_wall_pause_write(walls[i], mins);
    printf("paused %s for %lld min (auto-resumes)\n", wall, mins);
    return 0;
}
int kai_cmd_resume(int argc, char **argv) {
    if (refuse_if_agent("resume")) return 3;
    const char *wall = argc >= 1 ? argv[0] : "all";
    const char *walls[] = { "storage", "network" };
    for (int i = 0; i < 2; i++)
        if (!strcmp(wall, "all") || !strcmp(wall, walls[i]))
            kai_wall_pause_write(walls[i], 0);
    printf("resumed %s\n", wall);
    return 0;
}

int kai_cmd_grant(int argc, char **argv) {
    const char *sub = argc > 0 ? argv[0] : "list";
    if (!strcmp(sub, "list")) return grant_list(argc > 1 && !strcmp(argv[1], "--json"), NULL);
    if (!strcmp(sub, "revoke")) return grant_revoke(argc > 1 ? argv[1] : NULL);
    if (!strcmp(sub, "create")) return grant_create(argc - 1, argv + 1);
    fprintf(stderr, "usage: kai grant [list [--json] | create ... | revoke <id>]\n");
    return 2;
}

/* ---- Session registry CLI (S1), read-only ---- */

static const char *sess_state(const kai_session *s) { return s->ended_utc ? "ended" : "active"; }

static int sessions_list(int json) {
    kai_session *s = NULL; int n = 0;
    kai_sessions_load(&s, &n);
    if (json) {
        printf("[");
        for (int i = 0; i < n; i++)
            printf("%s{\"id\":\"%s\",\"agent\":\"%s\",\"project\":\"%s\",\"host_app\":\"%s\","
                   "\"started_utc\":%lld,\"ended_utc\":%lld,\"state\":\"%s\"}",
                   i ? "," : "", s[i].id, s[i].agent, s[i].project, s[i].host_app,
                   s[i].started_utc, s[i].ended_utc, sess_state(&s[i]));
        printf("]\n");
    } else {
        printf("%-38s %-8s %-7s %-20s %s\n", "session", "agent", "state", "host", "project");
        for (int i = 0; i < n; i++)
            printf("%-38s %-8s %-7s %-20s %s\n", s[i].id, s[i].agent, sess_state(&s[i]),
                   s[i].host_app[0] ? s[i].host_app : "-", s[i].project);
        if (n == 0) printf("(no sessions)\n");
    }
    free(s);
    return 0;
}

static int session_show(const char *id) {
    if (!id || !*id) { fprintf(stderr, "usage: kai session show <id>\n"); return 2; }
    kai_session s;
    if (!kai_session_get(id, &s)) { fprintf(stderr, "kai session: no session '%s'\n", id); return 1; }
    printf("session   %s\n", s.id);
    printf("agent     %s%s%s\n", s.agent, s.agent_version[0] ? " " : "", s.agent_version);
    printf("state     %s\n", sess_state(&s));
    printf("project   %s\n", s.project);
    printf("host app  %s\n", s.host_app[0] ? s.host_app : "-");
    printf("root pid  %d (pidversion %llu)\n", s.root_pid, s.root_pidversion);
    printf("started   %lld\n", s.started_utc);
    if (s.ended_utc) printf("ended     %lld\n", s.ended_utc);
    printf("\ngrants for this session:\n");
    grant_list(0, s.id);
    return 0;
}

/* `kai sessions [--json]` */
int kai_cmd_sessions(int argc, char **argv) {
    return sessions_list(argc > 0 && !strcmp(argv[0], "--json"));
}

/* `kai session show <id>` (or `kai session <id>`) */
int kai_cmd_session(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[0], "show")) return session_show(argv[1]);
    if (argc >= 1 && strcmp(argv[0], "show") != 0) return session_show(argv[0]);
    fprintf(stderr, "usage: kai session show <id>\n");
    return 2;
}

/* `kai grants [--json] [--session <id>]` (plural: read-only listing) */
int kai_cmd_grants(int argc, char **argv) {
    int json = 0; const char *session = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--session") && i + 1 < argc) session = argv[++i];
    }
    return grant_list(json, session);
}
