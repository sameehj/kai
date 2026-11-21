/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * 0.4 opt-in activity recorder. With `record_activity on` in the policy, every
 * agent tool hook appends ONE metadata line to <kai home>/activity.jsonl:
 *
 *   {"ts":..,"agent":..,"session":..,"workspace":<cwd>,"tool":..,
 *    "op":"read|edit|write|command|mcp|tool","path":<file tools only>,
 *    "cmd0":<first word of a shell command only>,"mcp_server":..,"decision":..}
 *
 * Never tool arguments, file contents, prompts or full command lines. Off by
 * default. The file rotates daily (activity-YYYYMMDD.jsonl) and rotated files
 * older than 7 days are deleted. Cost: one stat, one append.
 *
 * `kai activity --json [--since 24h] [--workspace PATH]` reads them back
 * grouped per agent and operation, repeated reads of a path collapsed.
 *
 * 0.5: also per session ("sessions"), keyed by Kai's session key ("ks", the
 * key `kai snapshot` lists as activity_keys; older lines fall back to the
 * agent's own conversation id): counts per operation, stops, and the newest
 * KAI_ACTIVITY_SESSION_EVENTS events (time, operation, path / first word of a
 * command / MCP server, decision). "first_record" is the oldest line read.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "cJSON.h"
#include "internal.h"
#include "kai.h"

#define KAI_ACTIVITY_KEEP_DAYS 7
#define KAI_ACTIVITY_SESSION_EVENTS 40
#define KAI_ACTIVITY_MAX_SESSIONS 64

static void activity_path(char *out, size_t n) { snprintf(out, n, "%s/activity.jsonl", kai_home()); }

/* The first word of a shell command, without a leading path, skipping
 * VAR=value assignments (their values can be secrets). */
void kai_activity_cmd0(const char *cmd, char *out, size_t n) {
    if (!n) return;
    out[0] = '\0';
    if (!cmd) return;
    const char *c = cmd;
    for (;;) {
        while (*c == ' ' || *c == '\t' || *c == '\n' || *c == '(') c++;
        const char *e = c;
        while (*e && *e != ' ' && *e != '\t' && *e != '\n' && *e != ';' && *e != '|' && *e != '&') e++;
        if (e == c) return;
        const char *eq = memchr(c, '=', (size_t)(e - c));
        if (eq && eq > c) { c = e; continue; }   /* FOO=bar cmd */
        const char *b = c;
        for (const char *q = c; q < e; q++) if (*q == '/') b = q + 1;
        size_t l = (size_t)(e - b);
        if (l >= n) l = n - 1;
        if (l > 40) l = 40;
        size_t k = 0;
        for (size_t i = 0; i < l; i++) {
            char ch = b[i];
            if (ch == '"' || ch == '\'' || ch == '`' || ch == '$') continue;
            out[k++] = ch;
        }
        out[k] = '\0';
        return;
    }
}

static void day_of(time_t t, char *out, size_t n) {
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, n, "%Y%m%d", &tm);
}

/* Rotate activity.jsonl when it was last written on an earlier day, then
 * delete rotated files older than KAI_ACTIVITY_KEEP_DAYS. */
static void rotate(const char *path, time_t now) {
    struct stat st;
    if (stat(path, &st) != 0) return;
    char d1[16], d2[16];
    day_of(st.st_mtime, d1, sizeof d1);
    day_of(now, d2, sizeof d2);
    if (!strcmp(d1, d2)) return;
    char dest[1200];
    snprintf(dest, sizeof dest, "%s/activity-%s.jsonl", kai_home(), d1);
    if (access(dest, F_OK) == 0) {   /* append to an existing rotated file for that day */
        FILE *in = fopen(path, "rb"), *out = fopen(dest, "ab");
        if (in && out) {
            char buf[8192];
            size_t r;
            while ((r = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, r, out);
        }
        if (in) fclose(in);
        if (out) fclose(out);
        unlink(path);
    } else {
        rename(path, dest);
    }
    DIR *d = opendir(kai_home());
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, "activity-", 9) || !strstr(de->d_name, ".jsonl")) continue;
        char f[1200];
        snprintf(f, sizeof f, "%s/%s", kai_home(), de->d_name);
        if (stat(f, &st) == 0 && now - st.st_mtime > (time_t)KAI_ACTIVITY_KEEP_DAYS * 86400) unlink(f);
    }
    closedir(d);
}

void kai_activity_record(const kai_policy *p, const char *agent, const char *session, const char *ksession,
                         const char *cwd, const char *tool, const char *op, const char *path, const char *cmd,
                         const char *mcp_server, const char *decision) {
    /* 0.5: a health probe (kai status' self-test) is not agent activity. */
    if (!kai_policy_record_activity(p) || !op || kai_audit_suppressed()) return;
    char file[1100];
    activity_path(file, sizeof file);
    time_t now = time(NULL);
    rotate(file, now);
    cJSON *o = cJSON_CreateObject();
    if (!o) return;
    cJSON_AddNumberToObject(o, "ts", (double)now);
    cJSON_AddStringToObject(o, "agent", agent ? agent : "unknown");
    if (session && *session) cJSON_AddStringToObject(o, "session", session);
    if (ksession && *ksession) cJSON_AddStringToObject(o, "ks", ksession);
    if (cwd && *cwd) cJSON_AddStringToObject(o, "workspace", cwd);
    if (tool && *tool) cJSON_AddStringToObject(o, "tool", tool);
    cJSON_AddStringToObject(o, "op", op);
    if (path && *path && strcmp(op, "command") && strcmp(op, "mcp")) {
        char abs[1400];
        if (path[0] != '/' && path[0] != '~' && cwd && *cwd) snprintf(abs, sizeof abs, "%s/%s", cwd, path);
        else kai_strlcpy(abs, path, sizeof abs);
        cJSON_AddStringToObject(o, "path", abs);
    }
    if (cmd && !strcmp(op, "command")) {
        char c0[48];
        kai_activity_cmd0(cmd, c0, sizeof c0);
        if (*c0) cJSON_AddStringToObject(o, "cmd0", c0);
    }
    if (mcp_server && *mcp_server) cJSON_AddStringToObject(o, "mcp_server", mcp_server);
    cJSON_AddStringToObject(o, "decision", decision && *decision ? decision : "allow");
    char *line = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!line) return;
    int fd = open(file, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) {
        size_t l = strlen(line);
        line[l] = '\n';   /* PrintUnformatted leaves room only for the NUL: write it as two parts */
        (void)!write(fd, line, l + 1);
        close(fd);
    }
    free(line);
}

/* ---------- kai activity ---------- */

typedef struct {
    char agent[32], op[16];
    long count, stops;
    double first, last;
    cJSON *paths;     /* name -> count (path, cmd0 or mcp_server) */
    cJSON *sessions;  /* id -> 1 */
} group_t;

typedef struct { double ts; char op[16]; char name[512]; char decision[16]; } sev_t;
typedef struct {
    char key[96], agent[32], workspace[512];
    double first, last, ws_last;
    long counts[6], stops;
    sev_t *ev; int nev, capev;
} sess_t;
static const char *const OPS[6] = {"read", "edit", "write", "command", "mcp", "tool"};
typedef struct { sess_t s[KAI_ACTIVITY_MAX_SESSIONS]; int n; double first_record; } sessions_t;

static int op_index(const char *op) {
    for (int i = 0; i < 6; i++) if (!strcmp(OPS[i], op)) return i;
    return 5;
}

static void session_add(sessions_t *ss, const char *key, const char *agent, const char *ws, double ts,
                        const char *op, const char *name, const char *dec) {
    if (ss->first_record == 0 || ts < ss->first_record) ss->first_record = ts;
    sess_t *s = NULL;
    for (int i = 0; i < ss->n; i++) if (!strcmp(ss->s[i].key, key)) { s = &ss->s[i]; break; }
    if (!s) {
        if (ss->n == KAI_ACTIVITY_MAX_SESSIONS) {   /* bounded: replace the least recent session */
            int old = 0;
            for (int i = 1; i < ss->n; i++) if (ss->s[i].last < ss->s[old].last) old = i;
            if (ss->s[old].last > ts) return;
            free(ss->s[old].ev);
            s = &ss->s[old];
        } else s = &ss->s[ss->n++];
        memset(s, 0, sizeof *s);
        kai_strlcpy(s->key, key, sizeof s->key);
        kai_strlcpy(s->agent, agent, sizeof s->agent);
        s->first = ts;
    }
    if (ts < s->first) s->first = ts;
    if (ts > s->last) s->last = ts;
    if (ws && *ws && ts >= s->ws_last) { kai_strlcpy(s->workspace, ws, sizeof s->workspace); s->ws_last = ts; }
    s->counts[op_index(op)]++;
    int stop = dec && (!strcmp(dec, "block") || !strcmp(dec, "deny"));
    if (stop) s->stops++;
    /* keep the newest events: an array kept to at most 2x the cap, trimmed when output */
    if (s->nev == s->capev) {
        if (s->capev >= 4 * KAI_ACTIVITY_SESSION_EVENTS) {
            int oldest = 0;   /* drop the oldest to make room */
            for (int i = 1; i < s->nev; i++) if (s->ev[i].ts < s->ev[oldest].ts) oldest = i;
            if (s->ev[oldest].ts > ts) return;
            s->ev[oldest] = s->ev[--s->nev];
        } else {
            int nc = s->capev ? s->capev * 2 : 16;
            sev_t *ne = realloc(s->ev, (size_t)nc * sizeof *ne);
            if (!ne) return;
            s->ev = ne; s->capev = nc;
        }
    }
    sev_t *e = &s->ev[s->nev++];
    memset(e, 0, sizeof *e);
    e->ts = ts;
    kai_strlcpy(e->op, op, sizeof e->op);
    if (name) kai_strlcpy(e->name, name, sizeof e->name);
    kai_strlcpy(e->decision, dec && *dec ? dec : "allow", sizeof e->decision);
}

static int sev_newest_first(const void *a, const void *b) {
    double x = ((const sev_t *)a)->ts, y = ((const sev_t *)b)->ts;
    return x < y ? 1 : x > y ? -1 : 0;
}

static long parse_since(const char *s) {
    if (!s || !*s) return 86400;
    char *e;
    long v = strtol(s, &e, 10);
    if (v <= 0) return 86400;
    switch (*e) {
    case 'm': return v * 60;
    case 'h': return v * 3600;
    case 'd': return v * 86400;
    case 's': case '\0': return v;
    default: return 86400;
    }
}

static int in_workspace(const char *ws, const char *want) {
    if (!want || !*want) return 1;
    if (!ws) return 0;
    size_t l = strlen(want);
    while (l > 1 && want[l - 1] == '/') l--;
    return !strncmp(ws, want, l) && (ws[l] == '\0' || ws[l] == '/');
}

static void read_file(const char *f, double since, const char *want, group_t **gs, int *ng, int *cap,
                      sessions_t *ss) {
    FILE *fp = fopen(f, "rb");
    if (!fp) return;
    char line[8192];
    while (fgets(line, sizeof line, fp)) {
        cJSON *o = cJSON_Parse(line);
        if (!o) continue;
        const cJSON *ts = cJSON_GetObjectItem(o, "ts");
        const char *agent = cJSON_GetStringValue(cJSON_GetObjectItem(o, "agent"));
        const char *op = cJSON_GetStringValue(cJSON_GetObjectItem(o, "op"));
        const char *ws = cJSON_GetStringValue(cJSON_GetObjectItem(o, "workspace"));
        if (!cJSON_IsNumber(ts) || ts->valuedouble < since || !agent || !op || !in_workspace(ws, want)) {
            cJSON_Delete(o);
            continue;
        }
        /* 0.4.1 recorded kai status' health probe (a read of a Kai home's
         * audit.log with no session): not agent activity, skip those lines. */
        if (!cJSON_GetObjectItem(o, "session") && !cJSON_GetObjectItem(o, "ks")) {
            const char *pth = cJSON_GetStringValue(cJSON_GetObjectItem(o, "path"));
            size_t pl = pth ? strlen(pth) : 0;
            if (pl >= 10 && !strcmp(pth + pl - 10, "/audit.log")) { cJSON_Delete(o); continue; }
        }
        group_t *g = NULL;
        for (int i = 0; i < *ng; i++)
            if (!strcmp((*gs)[i].agent, agent) && !strcmp((*gs)[i].op, op)) { g = &(*gs)[i]; break; }
        if (!g) {
            if (*ng == *cap) {
                *cap = *cap ? *cap * 2 : 8;
                *gs = realloc(*gs, (size_t)*cap * sizeof **gs);
            }
            g = &(*gs)[(*ng)++];
            memset(g, 0, sizeof *g);
            kai_strlcpy(g->agent, agent, sizeof g->agent);
            kai_strlcpy(g->op, op, sizeof g->op);
            g->paths = cJSON_CreateObject();
            g->sessions = cJSON_CreateObject();
            g->first = ts->valuedouble;
        }
        g->count++;
        if (ts->valuedouble < g->first) g->first = ts->valuedouble;
        if (ts->valuedouble > g->last) g->last = ts->valuedouble;
        const char *dec = cJSON_GetStringValue(cJSON_GetObjectItem(o, "decision"));
        if (dec && (!strcmp(dec, "block") || !strcmp(dec, "deny"))) g->stops++;
        const char *key = cJSON_GetStringValue(cJSON_GetObjectItem(o, "path"));
        if (!key) key = cJSON_GetStringValue(cJSON_GetObjectItem(o, "cmd0"));
        if (!key) key = cJSON_GetStringValue(cJSON_GetObjectItem(o, "mcp_server"));
        if (key) {
            cJSON *c = cJSON_GetObjectItem(g->paths, key);
            if (c) cJSON_SetNumberValue(c, c->valuedouble + 1);
            else cJSON_AddNumberToObject(g->paths, key, 1);
        }
        const char *sess = cJSON_GetStringValue(cJSON_GetObjectItem(o, "session"));
        if (sess && !cJSON_GetObjectItem(g->sessions, sess)) cJSON_AddNumberToObject(g->sessions, sess, 1);
        if (ss) {
            const char *ks = cJSON_GetStringValue(cJSON_GetObjectItem(o, "ks"));
            char key[96];
            if (ks && *ks) snprintf(key, sizeof key, "%s", ks);
            else if (sess && *sess) snprintf(key, sizeof key, "conv:%.80s", sess);
            else snprintf(key, sizeof key, "agent:%.80s", agent);
            const char *nm = cJSON_GetStringValue(cJSON_GetObjectItem(o, "path"));
            if (!nm) nm = cJSON_GetStringValue(cJSON_GetObjectItem(o, "cmd0"));
            if (!nm) nm = cJSON_GetStringValue(cJSON_GetObjectItem(o, "mcp_server"));
            session_add(ss, key, agent, ws, ts->valuedouble, op, nm, dec);
        }
        cJSON_Delete(o);
    }
    fclose(fp);
}

int kai_cmd_activity(int argc, char **argv) {
    int json = 0;
    const char *since_s = "24h", *want = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--since") && i + 1 < argc) since_s = argv[++i];
        else if (!strcmp(argv[i], "--workspace") && i + 1 < argc) want = argv[++i];
        else {
            fprintf(stderr, "usage: kai activity --json [--since 24h] [--workspace PATH]\n");
            return 2;
        }
    }
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    int on = kai_policy_record_activity(p);
    kai_policy_free(p);
    double now = (double)time(NULL), since = now - (double)parse_since(since_s);

    group_t *gs = NULL;
    int ng = 0, cap = 0;
    sessions_t *ss = calloc(1, sizeof *ss);
    DIR *d = opendir(kai_home());
    if (d) {
        struct dirent *de;
        while ((de = readdir(d))) {
            if (strcmp(de->d_name, "activity.jsonl") &&
                (strncmp(de->d_name, "activity-", 9) || !strstr(de->d_name, ".jsonl")))
                continue;
            char f[1200];
            snprintf(f, sizeof f, "%s/%s", kai_home(), de->d_name);
            read_file(f, since, want, &gs, &ng, &cap, ss);
        }
        closedir(d);
    }

    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "recording", on);
    cJSON_AddNumberToObject(o, "since", since);
    if (want) cJSON_AddStringToObject(o, "workspace", want);
    cJSON *arr = cJSON_AddArrayToObject(o, "groups");
    long total = 0;
    for (int i = 0; i < ng; i++) {
        group_t *g = &gs[i];
        total += g->count;
        cJSON *r = cJSON_CreateObject();
        cJSON_AddStringToObject(r, "agent", g->agent);
        cJSON_AddStringToObject(r, "op", g->op);
        cJSON_AddNumberToObject(r, "count", (double)g->count);
        cJSON_AddNumberToObject(r, "distinct", (double)cJSON_GetArraySize(g->paths));
        cJSON_AddNumberToObject(r, "sessions", (double)cJSON_GetArraySize(g->sessions));
        cJSON_AddNumberToObject(r, "stops", (double)g->stops);
        cJSON_AddNumberToObject(r, "first", g->first);
        cJSON_AddNumberToObject(r, "last", g->last);
        /* the most-used names first, up to 20; repeated reads collapse into a count */
        cJSON *items = cJSON_AddArrayToObject(r, "items");
        int n = cJSON_GetArraySize(g->paths);
        char *used = calloc((size_t)n + 1, 1);
        for (int k = 0; k < n && k < 20; k++) {
            int best = -1;
            double bc = -1;
            int idx = 0;
            for (cJSON *c = g->paths->child; c; c = c->next, idx++)
                if (!used[idx] && c->valuedouble > bc) { bc = c->valuedouble; best = idx; }
            if (best < 0) break;
            used[best] = 1;
            cJSON *c = cJSON_GetArrayItem(g->paths, best);
            cJSON *it = cJSON_CreateObject();
            cJSON_AddStringToObject(it, "name", c->string);
            cJSON_AddNumberToObject(it, "count", c->valuedouble);
            cJSON_AddItemToArray(items, it);
        }
        free(used);
        cJSON_AddItemToArray(arr, r);
        cJSON_Delete(g->paths);
        cJSON_Delete(g->sessions);
    }
    free(gs);
    cJSON_AddNumberToObject(o, "total", (double)total);
    if (ss) {
        cJSON_AddNumberToObject(o, "first_record", ss->first_record);
        cJSON *sa = cJSON_AddArrayToObject(o, "sessions");
        for (int i = 0; i < ss->n; i++) {
            sess_t *s = &ss->s[i];
            cJSON *r = cJSON_CreateObject();
            cJSON_AddStringToObject(r, "key", s->key);
            cJSON_AddStringToObject(r, "agent", s->agent);
            cJSON_AddStringToObject(r, "workspace", s->workspace);
            cJSON_AddNumberToObject(r, "first", s->first);
            cJSON_AddNumberToObject(r, "last", s->last);
            cJSON *c = cJSON_AddObjectToObject(r, "counts");
            for (int k = 0; k < 6; k++) cJSON_AddNumberToObject(c, OPS[k], (double)s->counts[k]);
            cJSON_AddNumberToObject(r, "stops", (double)s->stops);
            qsort(s->ev, (size_t)s->nev, sizeof *s->ev, sev_newest_first);
            cJSON *ea = cJSON_AddArrayToObject(r, "events");
            for (int k = 0; k < s->nev && k < KAI_ACTIVITY_SESSION_EVENTS; k++) {
                cJSON *e = cJSON_CreateObject();
                cJSON_AddNumberToObject(e, "ts", s->ev[k].ts);
                cJSON_AddStringToObject(e, "op", s->ev[k].op);
                if (s->ev[k].name[0]) cJSON_AddStringToObject(e, "name", s->ev[k].name);
                cJSON_AddStringToObject(e, "decision", s->ev[k].decision);
                cJSON_AddItemToArray(ea, e);
            }
            cJSON_AddItemToArray(sa, r);
            free(s->ev);
        }
        free(ss);
    }
    char *s = json ? cJSON_PrintUnformatted(o) : cJSON_Print(o);
    if (s) { printf("%s\n", s); free(s); }
    cJSON_Delete(o);
    return 0;
}
