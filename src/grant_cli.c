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
#include "cJSON.h"

#include <stdio.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void grants_dir(char *buf, size_t n) { snprintf(buf, n, "%s/grants", kai_home()); }

/* M1.3: an agent-attributed process must never create or revoke grants. Best-
 * effort: if our own process tree traces to a known agent, refuse. (A human
 * terminal has no agent ancestor.) */
/* -1: determine from this process's own tree (the CLI in the test seam).
 * 0/1: forced by the control service, which already decided from the client's
 * audit token - the only trustworthy source when the write runs in the app. */
static int g_forced_agent = -1;
static int caller_is_agent(void) {
    if (g_forced_agent >= 0) return g_forced_agent;
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;                     /* can't determine: don't block the human */
    char name[64]; int apid;
    int hit = kai_process_agent(p, (int)getpid(), name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}

static int grant_create(int argc, char **argv);
static int grant_revoke(const char *idprefix);

/* Server side of the control path: the app has verified the client; run the
 * grant write with that verdict. Only create/revoke write; list stays a read. */
int kai_grant_dispatch(int argc, char **argv, int caller_is_agent_flag) {
    g_forced_agent = caller_is_agent_flag;
    const char *sub = argc > 0 ? argv[0] : "";
    int rc;
    if (!strcmp(sub, "create")) rc = grant_create(argc - 1, argv + 1);
    else if (!strcmp(sub, "revoke")) rc = grant_revoke(argc > 1 ? argv[1] : NULL);
    else rc = 2;
    g_forced_agent = -1;
    return rc;
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

/* B2: pausing lowers protection, so it is accepted only from Kai's own app UI
 * (one click, time-boxed), never from a command an agent could run. kai resume
 * stays: it only turns checks back on. */
int kai_cmd_pause(int argc, char **argv) {
    (void)argc; (void)argv;
    fprintf(stderr, "Pause Kai from the menu bar: click Kai, then Pause Kai (15 minutes, resumes by itself).\n"
                    "(There is no pause command, so an agent can't pause Kai.)\n");
    return 4;
}
int kai_cmd_resume(int argc, char **argv) {
    if (refuse_if_agent("resume")) return 3;
    if (argc >= 2 && !strcmp(argv[0], "session")) {
        kai_session_pause_write(argv[1], 0);
        printf("resumed session %s\n", argv[1]);
        return 0;
    }
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
#ifndef KAI_TEST_DIRECT_POLICY
    /* v1: permissions are given and revoked only in Kai (the app is the one
     * writer); the CLI lists them. */
    if (!strcmp(sub, "create") || !strcmp(sub, "revoke")) return kai_cli_change_in_kai(argc, argv);
#endif
    if (!strcmp(sub, "revoke")) return grant_revoke(argc > 1 ? argv[1] : NULL);
    if (!strcmp(sub, "create")) return grant_create(argc - 1, argv + 1);
    fprintf(stderr, "usage: kai grant [list [--json] | create ... | revoke <id>]\n");
    return 2;
}

/* ---- Session registry CLI (S1), read-only ---- */

static const char *sess_state(const kai_session *s) { return s->ended_utc ? "ended" : "active"; }

/* One row of the Agent Control list. ONE definition, used by the list, the
 * popover count and `kai status`: live sessions are "working" (a command or
 * hook in the last 15 minutes) or "idle"; ended ones are separate. An IDE app
 * is one row holding its workspaces. */
#define ROW_MAX_WS 16
typedef struct {
    kai_session s;
    long long last;                 /* last activity (0 = none seen) */
    int nws;
    char ws[ROW_MAX_WS][512];
    long long wslast[ROW_MAX_WS];
} sess_row;

/* Working: a tool call in progress, or an event in the last 15 minutes. */
static int session_busy(const kai_session *s, long long now) {
    if (s->source != KAI_SESS_SCAN && kai_session_busy(s->id, now)) return 1;
    if (s->root_pid > 0) {
        char k[32]; snprintf(k, sizeof k, "pid-%d", s->root_pid);
        if (kai_session_busy(k, now)) return 1;
    }
    return 0;
}

static int row_working(const sess_row *r, long long now) {
    return kai_session_working(r->last, now) || session_busy(&r->s, now);
}

static const char *row_activity(const sess_row *r, long long now) {
    if (r->s.ended_utc) return "ended";
    return row_working(r, now) ? "working" : "idle";
}

/* A live record whose root runs under another live record's root of the same
 * agent (an older build keyed a child, e.g. Codex's app-server, to itself) is
 * folded into that session. */
static int root_is_nested(const kai_session *reg, int nr, int i) {
    int pid = reg[i].root_pid;
    for (int depth = 0; pid > 1 && depth < 64; depth++) {
        kai_proc pr;
        if (kai_proc_read_fast(pid, &pr) != 0) break;
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (parent <= 1 || parent == pid) break;
        for (int j = 0; j < nr; j++)
            if (j != i && reg[j].root_pid == parent && !strcmp(reg[j].agent, reg[i].agent) &&
                kai_session_live(&reg[j]))
                return 1;
        pid = parent;
    }
    return 0;
}

static int is_delegated(const kai_session *s) { return strstr(s->agent, " (delegated)") != NULL; }

/* A session's last activity, credited by SESSION: its Kai id, or - for agent
 * events the wall saw before it could name a session (it restarted under a
 * running agent) - the agent root's pid key. */
static long long session_last(const kai_session *s) {
    long long t = s->source == KAI_SESS_SCAN ? 0 : kai_session_last_active(s->id, NULL);
    if (s->root_pid > 0) {
        char k[32]; snprintf(k, sizeof k, "pid-%d", s->root_pid);
        long long u = kai_session_last_active(k, NULL);
        if (u > t) t = u;
    }
    return t;
}

static void row_add_ws(sess_row *r, const char *path) {
    if (!path || !*path || !strcmp(path, "/") || path[0] == '(') return;
    for (int i = 0; i < r->nws; i++) if (!strcmp(r->ws[i], path)) return;
    if (r->nws < ROW_MAX_WS) kai_strlcpy(r->ws[r->nws++], path, sizeof r->ws[0]);
}

/* Merge the ES registry (authoritative while the storage wall runs) with the
 * wall-free process scan, deduped by root pid (registry wins), then fold each
 * IDE app into one row. Delegated processes never own a session. Caller frees. */
static int session_rows(sess_row **out, int *n) {
    kai_session *reg = NULL; int nr = 0;
    kai_sessions_load(&reg, &nr);
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    kai_session *scan = NULL; int ns = 0;
    if (p) { kai_sessions_scan(p, &scan, &ns); kai_policy_free(p); }
    sess_row *rows = calloc((size_t)(nr + ns + 1), sizeof *rows);
    int c = 0;
    long long now = (long long)time(NULL);
    if (rows) {
        /* Ended: the 20 most recent of the last day; never mixed with live. */
        int nended = 0;
        for (int i = 0; i < nr; i++)
            if (!is_delegated(&reg[i]) && !kai_session_live(&reg[i]) && reg[i].ended_utc &&
                now - reg[i].ended_utc < 86400) nended++;
        long long cutoff = 0;
        if (nended > 20) {
            long long *ts = calloc((size_t)nended, sizeof *ts);
            int k = 0;
            for (int i = 0; ts && i < nr; i++)
                if (!is_delegated(&reg[i]) && !kai_session_live(&reg[i]) && reg[i].ended_utc &&
                    now - reg[i].ended_utc < 86400)
                    ts[k++] = reg[i].ended_utc;
            for (int a = 0; ts && a < 20; a++)          /* partial selection: 20th newest */
                for (int b2 = a + 1; b2 < k; b2++)
                    if (ts[b2] > ts[a]) { long long t = ts[a]; ts[a] = ts[b2]; ts[b2] = t; }
            if (ts) cutoff = ts[19];
            free(ts);
        }
        for (int i = 0; i < nr; i++) {
            if (is_delegated(&reg[i])) continue;
            int live = kai_session_live(&reg[i]);
            if (!live) {
                if (reg[i].ended_utc && now - reg[i].ended_utc < 86400 && reg[i].ended_utc >= cutoff) {
                    rows[c].s = reg[i]; rows[c].last = session_last(&reg[i]); c++;
                }
                continue;
            }
            if (root_is_nested(reg, nr, i)) continue;
            int newer = 0;
            for (int j = 0; j < nr && !newer; j++)
                if (j != i && !is_delegated(&reg[j]) && reg[j].root_pid == reg[i].root_pid &&
                    kai_session_live(&reg[j]) &&
                    (reg[j].started_utc > reg[i].started_utc ||
                     (reg[j].started_utc == reg[i].started_utc && strcmp(reg[j].id, reg[i].id) > 0)))
                    newer = 1;
            if (newer) continue;
            rows[c].s = reg[i];
            rows[c].last = session_last(&reg[i]);
            c++;
        }
        int nlive = c;
        for (int i = 0; i < ns; i++) {
            int dup = 0;
            for (int j = 0; j < nlive; j++)
                if (!rows[j].s.ended_utc && rows[j].s.root_pid != 0 && rows[j].s.root_pid == scan[i].root_pid) {
                    /* the wall's record wins, but keep what only the scan knows */
                    if (!rows[j].s.tty[0]) kai_strlcpy(rows[j].s.tty, scan[i].tty, sizeof rows[j].s.tty);
                    if (!rows[j].s.host_app[0])
                        kai_strlcpy(rows[j].s.host_app, scan[i].host_app, sizeof rows[j].s.host_app);
                    rows[j].s.kind = scan[i].kind;
                    if (kai_agent_product_kind(scan[i].agent) == KAI_AGENT_IDE) row_add_ws(&rows[j], scan[i].project);
                    dup = 1; break;
                }
            if (!dup) { rows[c].s = scan[i]; rows[c].last = session_last(&scan[i]); c++; }   /* root-pid key only */
        }

        /* One row per IDE app: its live rows' workspaces, each working or idle
         * by the activity recorded in that folder. */
        for (int i = 0; i < c; i++) {
            if (rows[i].s.ended_utc || kai_agent_product_kind(rows[i].s.agent) != KAI_AGENT_IDE) continue;
            sess_row *h = &rows[i];
            row_add_ws(h, h->s.project);
            char sids[32][KAI_SESSION_ID_MAX]; int nsid = 0;
            if (h->s.source != KAI_SESS_SCAN) kai_strlcpy(sids[nsid++], h->s.id, sizeof sids[0]);
            long long app_last = h->last;
            for (int j = i + 1; j < c; j++) {
                if (rows[j].s.ended_utc || strcmp(rows[j].s.agent, h->s.agent)) continue;
                if (rows[j].last > app_last) app_last = rows[j].last;
                row_add_ws(h, rows[j].s.project);
                for (int w = 0; w < rows[j].nws; w++) row_add_ws(h, rows[j].ws[w]);
                if (rows[j].s.source != KAI_SESS_SCAN && nsid < 32) kai_strlcpy(sids[nsid++], rows[j].s.id, sizeof sids[0]);
                if (h->s.source == KAI_SESS_SCAN && rows[j].s.source != KAI_SESS_SCAN) {
                    kai_session keep = h->s;            /* prefer the wall's id for the row */
                    h->s = rows[j].s;
                    if (!h->s.host_app[0]) kai_strlcpy(h->s.host_app, keep.host_app, sizeof h->s.host_app);
                }
                if (rows[j].s.started_utc && (!h->s.started_utc || rows[j].s.started_utc < h->s.started_utc))
                    h->s.started_utc = rows[j].s.started_utc;
                rows[j] = rows[--c]; j--;               /* folded into h */
            }
            /* The row is working if any of its sessions had an agent event
             * (prompt, tool call, file or network) - credited by session, not
             * by folder. Per-workspace times are a best-effort detail. */
            h->last = app_last;
            for (int w = 0; w < h->nws; w++) {
                h->wslast[w] = 0;
                for (int k = 0; k < nsid; k++) {
                    long long t = kai_session_last_active(sids[k], h->ws[w]);
                    if (t > h->wslast[w]) h->wslast[w] = t;
                }
            }
            h->s.project[0] = '\0';
        }
    }
    free(reg); free(scan);
    *out = rows; *n = c;
    return c;
}

/* The popover headline and `kai status` count: live interactive rows working now. */
int kai_sessions_working_count(void) {
    sess_row *r = NULL; int n = 0;
    session_rows(&r, &n);
    long long now = (long long)time(NULL);
    int w = 0;
    for (int i = 0; i < n; i++)
        if (!r[i].s.ended_utc && r[i].s.kind == KAI_KIND_SESSION && row_working(&r[i], now)) w++;
    free(r);
    return w;
}

static void ago(long long secs, char *out, size_t n) {
    if (secs < 60) snprintf(out, n, "%llds", secs);
    else if (secs < 3600) snprintf(out, n, "%lldm", secs / 60);
    else if (secs < 86400) snprintf(out, n, "%lldh %lldm", secs / 3600, (secs % 3600) / 60);
    else snprintf(out, n, "%lldd", secs / 86400);
}

static int sessions_list(int json) {
    sess_row *r = NULL; int n = 0;
    session_rows(&r, &n);
    long long now = (long long)time(NULL);
    /* Labels from the same measured, verified levels as the headline. */
    const char *enf = kai_enforcement_from_levels(kai_wall_observed_level("storage"),
                                                  kai_wall_observed_level("network"));
    if (json) {
        /* cJSON escapes every string (a topic with a newline used to break it). */
        cJSON *arr = cJSON_CreateArray();
        for (int i = 0; i < n; i++) {
            const kai_session *s = &r[i].s;
            char topic[128] = "";
            kai_session_report_get(s->id, topic, sizeof topic);
            /* topic is agent-reported + already redacted; shown, never trusted. */
            cJSON *o = cJSON_CreateObject();
            cJSON_AddStringToObject(o, "id", s->id);
            cJSON_AddStringToObject(o, "agent", s->agent);
            cJSON_AddStringToObject(o, "topic", topic);
            cJSON_AddBoolToObject(o, "topic_reported_by_agent", 1);
            cJSON_AddStringToObject(o, "project", s->project);
            cJSON_AddStringToObject(o, "host_app", s->host_app);
            cJSON_AddStringToObject(o, "tty", s->tty);
            cJSON_AddNumberToObject(o, "started_utc", (double)s->started_utc);
            cJSON_AddNumberToObject(o, "ended_utc", (double)s->ended_utc);
            cJSON_AddNumberToObject(o, "last_active_utc", (double)r[i].last);
            cJSON_AddStringToObject(o, "activity", row_activity(&r[i], now));
            cJSON_AddNumberToObject(o, "child_count", s->child_count);
            cJSON_AddStringToObject(o, "source", s->source == KAI_SESS_SCAN ? "scan" : "es");
            cJSON_AddStringToObject(o, "kind", kai_session_kind_name(s->kind));
            cJSON_AddStringToObject(o, "enforcement", enf);
            cJSON_AddStringToObject(o, "state", sess_state(s));
            if (kai_agent_product_kind(s->agent) == KAI_AGENT_IDE && !s->ended_utc) {
                cJSON *ws = cJSON_AddArrayToObject(o, "workspaces");
                for (int w = 0; w < r[i].nws; w++) {
                    cJSON *x = cJSON_CreateObject();
                    cJSON_AddStringToObject(x, "path", r[i].ws[w]);
                    cJSON_AddNumberToObject(x, "last_active_utc", (double)r[i].wslast[w]);
                    cJSON_AddStringToObject(x, "activity",
                                            kai_session_working(r[i].wslast[w], now) ? "working" : "idle");
                    cJSON_AddItemToArray(ws, x);
                }
            }
            cJSON_AddItemToArray(arr, o);
        }
        char *js = cJSON_PrintUnformatted(arr);
        cJSON_Delete(arr);
        printf("%s\n", js ? js : "[]");
        free(js);
    } else {
        static const char *const SECTIONS[] = {"working", "idle", "ended"};
        static const char *const TITLES[] = {"Working now", "Idle", "Ended today"};
        for (int sct = 0; sct < 3; sct++) {
            int cnt = 0;
            for (int i = 0; i < n; i++)
                if (r[i].s.kind == KAI_KIND_SESSION && !strcmp(row_activity(&r[i], now), SECTIONS[sct])) cnt++;
            printf("%s (%d)\n", TITLES[sct], cnt);
            for (int i = 0; i < n; i++) {
                const kai_session *s = &r[i].s;
                if (s->kind != KAI_KIND_SESSION || strcmp(row_activity(&r[i], now), SECTIONS[sct])) continue;
                char when[32] = "-", where[600];
                if (r[i].last) ago(now - r[i].last, when, sizeof when);
                if (kai_agent_product_kind(s->agent) == KAI_AGENT_IDE && !s->ended_utc)
                    snprintf(where, sizeof where, "%d workspace%s", r[i].nws, r[i].nws == 1 ? "" : "s");
                else
                    snprintf(where, sizeof where, "%s", s->project);
                printf("  %-8.8s %-8s %-9s %-28.28s last active %-7s %s\n", s->id, s->agent,
                       s->tty[0] ? s->tty : (s->host_app[0] ? s->host_app : "-"), where, when,
                       s->ended_utc ? "" : enf);
            }
        }
        /* Background services and orphans are listed apart, not counted as sessions. */
        for (int i = 0; i < n; i++) {
            if (r[i].s.kind == KAI_KIND_SESSION) continue;
            printf("  [%s] %-8s pid %-6d %s\n", kai_session_kind_name(r[i].s.kind),
                   r[i].s.agent, r[i].s.root_pid, r[i].s.project);
        }
    }
    free(r);
    return 0;
}

static int session_show(const char *id) {
    if (!id || !*id) { fprintf(stderr, "usage: kai session show <id>\n"); return 2; }
    kai_session s;
    if (!kai_session_get(id, &s)) { fprintf(stderr, "kai session: no session '%s'\n", id); return 1; }
    char topic[128] = "";
    kai_session_report_get(s.id, topic, sizeof topic);
    printf("session   %s\n", s.id);
    printf("agent     %s%s%s\n", s.agent, s.agent_version[0] ? " " : "", s.agent_version);
    if (topic[0]) printf("topic     %s  (reported by agent)\n", topic);
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

/* `kai snapshot --json`: what Agent Control shows - sessions and agents - in
 * ONE call, so the window doesn't wait on two CLI runs back to back. */
int kai_cmd_agents(int argc, char **argv);
int kai_cmd_snapshot(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("{\"sessions\":");
    fflush(stdout);
    sessions_list(1);
    printf(",\"agents\":");
    fflush(stdout);
    char *a[] = {"--json", NULL};
    kai_cmd_agents(1, a);
    fflush(stdout);
    printf("}\n");
    return 0;
}

/* `kai pending [--json]`: the decision cards waiting for you (read-only) -
 * what Kai's popover shows under "Needs you". */
int kai_cmd_pending(int argc, char **argv) {
    int json = argc > 0 && !strcmp(argv[0], "--json");
    char dir[1200]; snprintf(dir, sizeof dir, "%s/pending", kai_home());
    DIR *d = opendir(dir);
    cJSON *arr = cJSON_CreateArray();
    struct dirent *e;
    while (d && (e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json")) continue;
        char p[1400]; snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        size_t len = 0; char *t = kai_read_file(p, 1 << 16, &len);
        cJSON *o = t ? cJSON_Parse(t) : NULL;
        free(t);
        if (o) cJSON_AddItemToArray(arr, o);
    }
    if (d) closedir(d);
    if (json) {
        char *js = cJSON_PrintUnformatted(arr);
        printf("%s\n", js ? js : "[]");
        free(js);
    } else {
        cJSON *o = NULL; int n = 0;
        cJSON_ArrayForEach(o, arr) {
            const char *ag = cJSON_GetStringValue(cJSON_GetObjectItem(o, "agent"));
            const char *op = cJSON_GetStringValue(cJSON_GetObjectItem(o, "op"));
            const char *rs = cJSON_GetStringValue(cJSON_GetObjectItem(o, "resource"));
            const char *ss = cJSON_GetStringValue(cJSON_GetObjectItem(o, "session"));
            printf("%-8s %-8s %-40s session %s\n", ag ? ag : "?", op ? op : "?", rs ? rs : "?",
                   ss && *ss ? ss : "(none)");
            n++;
        }
        if (!n) printf("(nothing waiting)\n");
    }
    cJSON_Delete(arr);
    return 0;
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
