/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Session registry (S1). One JSON file per session under <home>/registry,
 * written only by Kai components (the ES storage wall at root exec/exit, and
 * the app). The directory is inside the control store, so an agent tree cannot
 * create or alter a record. Reads (kai sessions / session show) are open to any
 * caller. The file backend is deliberately simple and encapsulated behind the
 * kai_session_* API; it could become SQLite later without touching callers.
 */
#include "internal.h"
#include "cJSON.h"

#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

const char *kai_session_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/registry", kai_home());
    return buf;
}

static void session_path(const char *id, char *out, size_t n) {
    snprintf(out, n, "%s/%s.json", kai_session_dir(), id);
}

/* Reject an id that could escape the registry dir or hold a path separator. */
static int id_ok(const char *id) {
    if (!id || !*id || strlen(id) >= KAI_SESSION_ID_MAX) return 0;
    for (const char *c = id; *c; c++)
        if (!(isalnum((unsigned char)*c) || *c == '-' || *c == '_')) return 0;
    return 1;
}

static int write_session(const kai_session *s) {
    cJSON *o = cJSON_CreateObject();
    if (!o) return -1;
    cJSON_AddStringToObject(o, "id", s->id);
    cJSON_AddStringToObject(o, "agent", s->agent);
    cJSON_AddStringToObject(o, "agent_version", s->agent_version);
    cJSON_AddNumberToObject(o, "root_pid", s->root_pid);
    cJSON_AddNumberToObject(o, "root_pidversion", (double)s->root_pidversion);
    cJSON_AddNumberToObject(o, "started_utc", (double)s->started_utc);
    cJSON_AddNumberToObject(o, "ended_utc", (double)s->ended_utc);
    cJSON_AddStringToObject(o, "project", s->project);
    cJSON_AddStringToObject(o, "host_app", s->host_app);
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;

    mkdir(kai_home(), 0700);
    mkdir(kai_session_dir(), 0700);
    char path[1200], tmp[1300];
    session_path(s->id, path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { free(js); return -1; }
    chmod(tmp, 0600);
    size_t len = strlen(js);
    int ok = fwrite(js, 1, len, f) == len;
    ok = (fflush(f) == 0) && ok;
    ok = (fclose(f) == 0) && ok;
    free(js);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int read_session(const char *path, kai_session *out) {
    size_t len = 0;
    char *txt = kai_read_file(path, 1 << 20, &len);
    if (!txt) return 0;
    cJSON *o = cJSON_Parse(txt);
    free(txt);
    if (!o) return 0;
    memset(out, 0, sizeof *out);
    const char *id = cJSON_GetStringValue(cJSON_GetObjectItem(o, "id"));
    if (!id_ok(id)) { cJSON_Delete(o); return 0; }
    kai_strlcpy(out->id, id, sizeof out->id);
#define STR(field) do { const char *v = cJSON_GetStringValue(cJSON_GetObjectItem(o, #field)); \
                        if (v) kai_strlcpy(out->field, v, sizeof out->field); } while (0)
#define NUM(field) do { cJSON *v = cJSON_GetObjectItem(o, #field); \
                        if (cJSON_IsNumber(v)) out->field = v->valuedouble; } while (0)
    STR(agent); STR(agent_version); STR(project); STR(host_app);
    NUM(root_pid); NUM(started_utc); NUM(ended_utc);
    { cJSON *v = cJSON_GetObjectItem(o, "root_pidversion");
      if (cJSON_IsNumber(v)) out->root_pidversion = (unsigned long long)v->valuedouble; }
#undef STR
#undef NUM
    cJSON_Delete(o);
    return 1;
}

int kai_session_begin(const kai_session *s) {
    if (!s || !id_ok(s->id)) return -1;
    return write_session(s);
}

/* Convenience for callers (the ES wall is Swift): assemble and begin from plain
 * C strings, so no Swift fixed-array copying is needed. */
int kai_session_record(const char *id, const char *agent, const char *agent_version,
                       int root_pid, unsigned long long root_pidversion,
                       const char *project, const char *host_app, long long started_utc) {
    if (!id_ok(id)) return -1;
    kai_session s; memset(&s, 0, sizeof s);
    kai_strlcpy(s.id, id, sizeof s.id);
    if (agent) kai_strlcpy(s.agent, agent, sizeof s.agent);
    if (agent_version) kai_strlcpy(s.agent_version, agent_version, sizeof s.agent_version);
    s.root_pid = root_pid;
    s.root_pidversion = root_pidversion;
    if (project) kai_strlcpy(s.project, project, sizeof s.project);
    if (host_app) kai_strlcpy(s.host_app, host_app, sizeof s.host_app);
    s.started_utc = started_utc;
    s.ended_utc = 0;
    return kai_session_begin(&s);
}

int kai_session_end(const char *id, long long ended_utc) {
    if (!id_ok(id)) return -1;
    char path[1200];
    session_path(id, path, sizeof path);
    kai_session s;
    if (!read_session(path, &s)) return -1;
    s.ended_utc = ended_utc;
    return write_session(&s);
}

int kai_session_get(const char *id, kai_session *out) {
    if (!id_ok(id) || !out) return 0;
    char path[1200];
    session_path(id, path, sizeof path);
    return read_session(path, out);
}

static int by_started_desc(const void *a, const void *b) {
    long long x = ((const kai_session *)a)->started_utc;
    long long y = ((const kai_session *)b)->started_utc;
    return x < y ? 1 : x > y ? -1 : 0;
}

int kai_sessions_load(kai_session **out, int *n) {
    *out = NULL; *n = 0;
    DIR *d = opendir(kai_session_dir());
    if (!d) return 0;
    kai_session *arr = NULL;
    int count = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json") != 0) continue;
        char path[1300];
        if (snprintf(path, sizeof path, "%s/%s", kai_session_dir(), e->d_name) >= (int)sizeof path)
            continue;
        kai_session s;
        if (!read_session(path, &s)) continue;
        if (count == cap) {
            int ncap = cap ? cap * 2 : 8;
            kai_session *na = realloc(arr, (size_t)ncap * sizeof *na);
            if (!na) break;
            arr = na; cap = ncap;
        }
        arr[count++] = s;
    }
    closedir(d);
    if (arr && count > 1) qsort(arr, (size_t)count, sizeof *arr, by_started_desc);
    *out = arr; *n = count;
    return count;
}
