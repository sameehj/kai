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

void kai_activity_record(const kai_policy *p, const char *agent, const char *session, const char *cwd,
                         const char *tool, const char *op, const char *path, const char *cmd,
                         const char *mcp_server, const char *decision) {
    if (!kai_policy_record_activity(p) || !op) return;
    char file[1100];
    activity_path(file, sizeof file);
    time_t now = time(NULL);
    rotate(file, now);
    cJSON *o = cJSON_CreateObject();
    if (!o) return;
    cJSON_AddNumberToObject(o, "ts", (double)now);
    cJSON_AddStringToObject(o, "agent", agent ? agent : "unknown");
    if (session && *session) cJSON_AddStringToObject(o, "session", session);
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

static void read_file(const char *f, double since, const char *want, group_t **gs, int *ng, int *cap) {
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
    DIR *d = opendir(kai_home());
    if (d) {
        struct dirent *de;
        while ((de = readdir(d))) {
            if (strcmp(de->d_name, "activity.jsonl") &&
                (strncmp(de->d_name, "activity-", 9) || !strstr(de->d_name, ".jsonl")))
                continue;
            char f[1200];
            snprintf(f, sizeof f, "%s/%s", kai_home(), de->d_name);
            read_file(f, since, want, &gs, &ng, &cap);
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
    char *s = json ? cJSON_PrintUnformatted(o) : cJSON_Print(o);
    if (s) { printf("%s\n", s); free(s); }
    cJSON_Delete(o);
    return 0;
}
