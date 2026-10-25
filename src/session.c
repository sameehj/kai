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
#include <time.h>
#include <unistd.h>

const char *kai_session_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/registry", kai_home());
    return buf;
}

static void session_path(const char *id, char *out, size_t n) {
    snprintf(out, n, "%s/%s.json", kai_session_dir(), id);
}

const char *kai_enforcement_label(int storage_active, int network_active) {
    if (storage_active && network_active) return "Enforced by both walls";
    if (network_active && !storage_active) return "Network wall only";
    if (storage_active && !network_active) return "Storage wall only";
    return "Seen, not enforced: storage wall off";
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
    cJSON_AddNumberToObject(o, "child_count", s->child_count);
    cJSON_AddNumberToObject(o, "source", s->source);
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
    NUM(root_pid); NUM(started_utc); NUM(ended_utc); NUM(child_count); NUM(source);
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

/* Per-session pause (S6): Kai skips only this session for a time-boxed window,
 * auto-resuming when it elapses. Mirrors the wall-wide pause: a file
 * <home>/pause-session-<id> holding an expiry epoch. Never-tier protections
 * (the control store) still apply while paused — that is enforced by the caller,
 * which only consults this for soft-protected resources. */
int kai_session_paused(const char *session, long long now) {
    if (!id_ok(session)) return 0;
    char fp[1200];
    snprintf(fp, sizeof fp, "%s/pause-session-%s", kai_home(), session);
    size_t n = 0;
    char *t = kai_read_file(fp, 64, &n);
    if (!t) return 0;
    long long until = strtoll(t, NULL, 10);
    free(t);
    return until > now;              /* expired/absent => not paused (auto-resume) */
}

int kai_session_pause_write(const char *session, long long minutes) {
    if (!id_ok(session)) return -1;
    mkdir(kai_home(), 0700);
    char fp[1200];
    snprintf(fp, sizeof fp, "%s/pause-session-%s", kai_home(), session);
    if (minutes <= 0) { unlink(fp); return 0; }   /* resume */
    long long until = (long long)time(NULL) + minutes * 60;
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", fp, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    chmod(tmp, 0600);
    int ok = fprintf(f, "%lld\n", until) > 0;
    ok = (fclose(f) == 0) && ok;
    if (!ok || rename(tmp, fp) != 0) { unlink(tmp); return -1; }
    return 0;
}

int kai_session_get(const char *id, kai_session *out) {
    if (!id_ok(id) || !out) return 0;
    char path[1200];
    session_path(id, path, sizeof path);
    return read_session(path, out);
}

/* ---- Descriptive session reports (S3) ----
 * Agent-reported topic, kept APART from the authoritative registry so it never
 * drives an authorization decision. Written by the signed kai hook (a Kai
 * component); the topic is redacted through libkai and truncated before it is
 * stored. A report binds only to an ES session id Kai itself observed, and an
 * agent session id already bound to a different ES session is rejected+logged.
 */
const char *kai_session_reports_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/reports", kai_home());
    return buf;
}

static void report_path(const char *es, char *out, size_t n) {
    snprintf(out, n, "%s/%s.json", kai_session_reports_dir(), es);
}

/* Back a byte cut off any partial UTF-8 trailing byte, then cap to <= max. */
static size_t utf8_trunc(const char *s, size_t max) {
    size_t n = strlen(s);
    if (n <= max) return n;
    n = max;
    while (n && ((unsigned char)s[n] & 0xC0) == 0x80) n--;
    return n;
}

/* Is `agent_session` already recorded under a report other than `es`? */
static int agent_session_bound_elsewhere(const char *agent_session, const char *es) {
    if (!agent_session || !*agent_session) return 0;
    DIR *d = opendir(kai_session_reports_dir());
    if (!d) return 0;
    struct dirent *e; int clash = 0;
    while (!clash && (e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json")) continue;
        char path[1300], esid[KAI_SESSION_ID_MAX] = "";
        snprintf(path, sizeof path, "%s/%s", kai_session_reports_dir(), e->d_name);
        size_t len = 0; char *txt = kai_read_file(path, 1 << 16, &len);
        if (!txt) continue;
        cJSON *o = cJSON_Parse(txt); free(txt);
        if (o) {
            const char *as = cJSON_GetStringValue(cJSON_GetObjectItem(o, "agent_session"));
            const char *e2 = cJSON_GetStringValue(cJSON_GetObjectItem(o, "es_session"));
            if (e2) kai_strlcpy(esid, e2, sizeof esid);
            if (as && strcmp(as, agent_session) == 0 && strcmp(esid, es) != 0) clash = 1;
            cJSON_Delete(o);
        }
    }
    closedir(d);
    return clash;
}

int kai_session_report_topic(const kai_policy *p, const char *es_session,
                             const char *agent_session, const char *raw_topic) {
    if (!id_ok(es_session)) return -1;   /* must be a Kai-observed ES session id */
    if (agent_session_bound_elsewhere(agent_session, es_session)) {
        kai_audit("session", "bind", "rejected", "",
                  "agent session id already bound to another Kai session");
        return -1;
    }
    /* Redact the topic through libkai so a secret in the first prompt never
     * reaches storage; if scanning is off we store a placeholder, never raw. */
    char topic[128] = "";
    if (raw_topic && *raw_topic && p) {
        kai_report rep;
        char *clean = kai_scan_text(p, raw_topic, &rep);
        if (clean) {
            size_t t = utf8_trunc(clean, 80);
            memcpy(topic, clean, t); topic[t] = '\0';
            free(clean);
        } else {
            kai_strlcpy(topic, "(topic not scanned)", sizeof topic);
        }
    }
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "es_session", es_session);
    cJSON_AddStringToObject(o, "agent_session", agent_session ? agent_session : "");
    cJSON_AddStringToObject(o, "topic", topic);
    cJSON_AddNumberToObject(o, "updated_utc", (double)time(NULL));
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;
    mkdir(kai_home(), 0700);
    mkdir(kai_session_reports_dir(), 0700);
    char path[1200], tmp[1300];
    report_path(es_session, path, sizeof path);
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

int kai_session_report_get(const char *es_session, char *topic, size_t topiclen) {
    if (topic && topiclen) topic[0] = '\0';
    if (!id_ok(es_session)) return 0;
    char path[1200];
    report_path(es_session, path, sizeof path);
    size_t len = 0; char *txt = kai_read_file(path, 1 << 16, &len);
    if (!txt) return 0;
    cJSON *o = cJSON_Parse(txt); free(txt);
    if (!o) return 0;
    const char *t = cJSON_GetStringValue(cJSON_GetObjectItem(o, "topic"));
    if (t && topic) kai_strlcpy(topic, t, topiclen);
    int found = t != NULL;
    cJSON_Delete(o);
    return found;
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
