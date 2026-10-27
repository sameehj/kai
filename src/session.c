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

void kai_sha256_hex(const void *data, size_t n, char out[65]);  /* sha256.c */

const char *kai_session_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/registry", kai_home());
    return buf;
}

static void session_path(const char *id, char *out, size_t n) {
    snprintf(out, n, "%s/%s.json", kai_session_dir(), id);
}

/* ---- Discovery (item 5): "looks like an agent — protect it?" ----
 * The network wall records when a process Kai does NOT recognize as an agent
 * connects to a model-API host. Correlated with the scan (does it spawn
 * shells?), that produces a SUGGESTION the user confirms — Kai never adds an
 * agent on its own. Records live under <home>/discovery, keyed by exe. */
int kai_host_is_model_api(const char *host) {
    if (!host || !*host) return 0;
    static const char *const H[] = {
        "anthropic.com", "claude.ai", "claude.com", "openai.com", "chatgpt.com",
        "openrouter.ai", "googleapis.com", "generativelanguage", "x.ai", "mistral.ai",
    };
    for (size_t i = 0; i < sizeof H / sizeof H[0]; i++)
        if (strstr(host, H[i])) return 1;
    return 0;
}

int kai_looks_like_agent(int contacted_model_api, int spawns_shells, int already_recognized) {
    return contacted_model_api && spawns_shells && !already_recognized;
}

static const char *discovery_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/discovery", kai_home());
    return buf;
}

/* A stable, filesystem-safe id for an exe path (so one file per program). */
static void exe_id(const char *exe, char *out, size_t n) {
    char h[65];
    kai_sha256_hex(exe, strlen(exe), h);
    snprintf(out, n, "%.16s", h);
}

int kai_discovery_record(const char *exe, const char *host) {
    if (!exe || !*exe || !kai_host_is_model_api(host)) return -1;
    mkdir(kai_home(), 0700);
    mkdir(discovery_dir(), 0700);
    char id[32]; exe_id(exe, id, sizeof id);
    char path[1300];
    snprintf(path, sizeof path, "%s/%s.json", discovery_dir(), id);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "exe", exe);
    cJSON_AddStringToObject(o, "host", host ? host : "");
    cJSON_AddNumberToObject(o, "last_utc", (double)time(NULL));
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;
    char tmp[1400];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { free(js); return -1; }
    chmod(tmp, 0600);
    int ok = fwrite(js, 1, strlen(js), f) == strlen(js);
    ok = (fclose(f) == 0) && ok;
    free(js);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

int kai_discovery_load(kai_discovery **out, int *n) {
    *out = NULL; *n = 0;
    DIR *d = opendir(discovery_dir());
    if (!d) return 0;
    kai_discovery *arr = NULL; int c = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json")) continue;
        char path[1300];
        snprintf(path, sizeof path, "%s/%s", discovery_dir(), e->d_name);
        size_t len = 0; char *txt = kai_read_file(path, 1 << 16, &len);
        if (!txt) continue;
        cJSON *o = cJSON_Parse(txt); free(txt);
        if (!o) continue;
        kai_discovery r; memset(&r, 0, sizeof r);
        const char *ex = cJSON_GetStringValue(cJSON_GetObjectItem(o, "exe"));
        const char *h = cJSON_GetStringValue(cJSON_GetObjectItem(o, "host"));
        cJSON *lu = cJSON_GetObjectItem(o, "last_utc");
        if (ex) kai_strlcpy(r.exe, ex, sizeof r.exe);
        if (h) kai_strlcpy(r.host, h, sizeof r.host);
        if (cJSON_IsNumber(lu)) r.last_utc = (long long)lu->valuedouble;
        cJSON_Delete(o);
        if (!r.exe[0]) continue;
        if (c == cap) { int nc = cap ? cap * 2 : 8; kai_discovery *na = realloc(arr, (size_t)nc * sizeof *na);
                        if (!na) break; arr = na; cap = nc; }
        arr[c++] = r;
    }
    closedir(d);
    *out = arr; *n = c;
    return c;
}

/* ---- AI chats (item 3) ----
 * The web UIs of the chat assistants, as opposed to the programmatic model
 * APIs. The data arrives ONLY from the Kai browser extension over native
 * messaging (src/native.c); the network wall is agent-only and never records a
 * non-agent flow. Site only — no full URL, no chat text is stored. These are
 * surfaced for awareness and are never gated (the walls protect files). */
int kai_host_is_ai_chat(const char *site) {
    if (!site || !*site) return 0;
    static const char *const H[] = {
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
        "copilot.microsoft.com", "perplexity.ai", "poe.com", "grok.com",
        "x.ai", "deepseek.com", "mistral.ai", "chat.mistral.ai",
    };
    for (size_t i = 0; i < sizeof H / sizeof H[0]; i++)
        if (strstr(site, H[i])) return 1;
    return 0;
}

static const char *chat_dir(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/chats", kai_home());
    return buf;
}

/* One record per site: the extension reporting the same site again just
 * refreshes its counts and last_utc. */
static void chat_id(const char *site, char *out, size_t n) {
    char h[65];
    kai_sha256_hex(site, strlen(site), h);
    snprintf(out, n, "%.16s", h);
}

int kai_chat_record(const char *site, int open_tabs, int redactions, int overrides) {
    if (!site || !*site || !kai_host_is_ai_chat(site)) return -1;
    mkdir(kai_home(), 0700);
    mkdir(chat_dir(), 0700);
    char id[32]; chat_id(site, id, sizeof id);
    char path[1300];
    snprintf(path, sizeof path, "%s/%s.json", chat_dir(), id);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "site", site);
    cJSON_AddNumberToObject(o, "last_utc", (double)time(NULL));
    cJSON_AddNumberToObject(o, "open_tabs", open_tabs < 0 ? 0 : open_tabs);
    cJSON_AddNumberToObject(o, "redactions", redactions < 0 ? 0 : redactions);
    cJSON_AddNumberToObject(o, "overrides", overrides < 0 ? 0 : overrides);
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;
    char tmp[1400];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { free(js); return -1; }
    chmod(tmp, 0600);
    int ok = fwrite(js, 1, strlen(js), f) == strlen(js);
    ok = (fclose(f) == 0) && ok;
    free(js);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

int kai_chat_load(kai_chat **out, int *n) {
    *out = NULL; *n = 0;
    DIR *d = opendir(chat_dir());
    if (!d) return 0;
    kai_chat *arr = NULL; int c = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json")) continue;
        char path[1300];
        snprintf(path, sizeof path, "%s/%s", chat_dir(), e->d_name);
        size_t len = 0; char *txt = kai_read_file(path, 1 << 16, &len);
        if (!txt) continue;
        cJSON *o = cJSON_Parse(txt); free(txt);
        if (!o) continue;
        kai_chat r; memset(&r, 0, sizeof r);
        const char *site = cJSON_GetStringValue(cJSON_GetObjectItem(o, "site"));
        cJSON *lu = cJSON_GetObjectItem(o, "last_utc");
        cJSON *ot = cJSON_GetObjectItem(o, "open_tabs");
        cJSON *rd = cJSON_GetObjectItem(o, "redactions");
        cJSON *ov = cJSON_GetObjectItem(o, "overrides");
        if (site) kai_strlcpy(r.site, site, sizeof r.site);
        if (cJSON_IsNumber(lu)) r.last_utc = (long long)lu->valuedouble;
        if (cJSON_IsNumber(ot)) r.open_tabs = (int)ot->valuedouble;
        if (cJSON_IsNumber(rd)) r.redactions = (int)rd->valuedouble;
        if (cJSON_IsNumber(ov)) r.overrides = (int)ov->valuedouble;
        cJSON_Delete(o);
        if (!r.site[0]) continue;
        if (c == cap) { int nc = cap ? cap * 2 : 8; kai_chat *na = realloc(arr, (size_t)nc * sizeof *na);
                        if (!na) break; arr = na; cap = nc; }
        arr[c++] = r;
    }
    closedir(d);
    *out = arr; *n = c;
    return c;
}

/* The session a process belongs to, from the Kai-observed pid->session map
 * (<home>/sessions/<pid>.json), walking up the ancestry. This is the session
 * model: the control service uses it to stamp a request's session from the
 * CALLER's audit token, so a caller cannot claim another session's id. 1 if
 * found. */
int kai_session_for_pid(int pid, unsigned long long live_pidv, char *out, size_t n) {
    if (n) out[0] = '\0';
    for (int i = 0; i < 24 && pid > 1; i++) {
        char path[640];
        snprintf(path, sizeof path, "%s/sessions/%d.json", kai_home(), pid);
        size_t len = 0;
        char *txt = kai_read_file(path, 1 << 16, &len);
        if (txt) {
            cJSON *o = cJSON_Parse(txt);
            free(txt);
            if (o) {
                const char *s = cJSON_GetStringValue(cJSON_GetObjectItem(o, "session"));
                cJSON *pv = cJSON_GetObjectItem(o, "pidversion");
                /* Item 6: a reused pid must not inherit the prior process's
                 * session. On the FIRST hop (the caller itself), require the
                 * recorded pidversion to match the live one; a mismatch means the
                 * file is stale (pid recycled), so ignore it. live_pidv == 0 means
                 * the caller can't supply it (e.g. an ancestry hop) -> trust. */
                int stale = (i == 0 && live_pidv != 0 && cJSON_IsNumber(pv) &&
                             (unsigned long long)pv->valuedouble != live_pidv);
                if (!stale && s && *s) kai_strlcpy(out, s, n);
                cJSON_Delete(o);
                if (out[0]) return 1;
            }
        }
        kai_proc pr;
        if (kai_proc_read_fast(pid, &pr) != 0) break;
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (parent <= 1 || parent == pid) break;
        pid = parent;
    }
    return out[0] != '\0';
}

int kai_classify_session(const char *cmdline, int has_tty, int parent_is_launchd,
                         long long age_sec, int nested_in_same_agent) {
    if (nested_in_same_agent) return KAI_KIND_NESTED;         /* inside another session's tree */
    const char *c = cmdline ? cmdline : "";
    /* The agent's own supervisor/daemon: Claude Code runs `claude … daemon run`
     * and `claude … --bg-pty-host …`; a no-tty process reparented to launchd is
     * likewise a background service, not an interactive session. */
    if (strstr(c, "daemon run") || strstr(c, "--bg-pty-host") || strstr(c, "--bg-") ||
        (parent_is_launchd && !has_tty))
        return KAI_KIND_BACKGROUND;
    if (!has_tty && age_sec > 24 * 3600) return KAI_KIND_ORPHAN;  /* idle, possibly orphaned */
    return KAI_KIND_SESSION;
}

const char *kai_session_kind_name(int kind) {
    switch (kind) {
    case KAI_KIND_NESTED: return "nested";
    case KAI_KIND_BACKGROUND: return "background service";
    case KAI_KIND_ORPHAN: return "idle, possibly orphaned";
    default: return "session";
    }
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
    cJSON_AddStringToObject(o, "tty", s->tty);
    cJSON_AddNumberToObject(o, "child_count", s->child_count);
    cJSON_AddNumberToObject(o, "source", s->source);
    cJSON_AddNumberToObject(o, "kind", s->kind);
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
    STR(agent); STR(agent_version); STR(project); STR(host_app); STR(tty);
    NUM(root_pid); NUM(started_utc); NUM(ended_utc); NUM(child_count); NUM(source); NUM(kind);
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
    /* Item 4: in the protected registry, so an agent can't pause its own session. */
    snprintf(fp, sizeof fp, "%s/registry/pause-session-%s", kai_home(), session);
    size_t n = 0;
    char *t = kai_read_file(fp, 64, &n);
    if (!t) return 0;
    long long until = strtoll(t, NULL, 10);
    free(t);
    return until > now;              /* expired/absent => not paused (auto-resume) */
}

/* The epoch the session's pause expires at (0 if not paused). Lets the UI show
 * "Paused until HH:MM". */
long long kai_session_pause_until(const char *session) {
    if (!id_ok(session)) return 0;
    char fp[1200];
    snprintf(fp, sizeof fp, "%s/registry/pause-session-%s", kai_home(), session);
    size_t n = 0;
    char *t = kai_read_file(fp, 64, &n);
    if (!t) return 0;
    long long until = strtoll(t, NULL, 10);
    free(t);
    return until > (long long)time(NULL) ? until : 0;
}

int kai_session_pause_write(const char *session, long long minutes) {
    if (!id_ok(session)) return -1;
    mkdir(kai_home(), 0700);
    char rdir[1200];
    snprintf(rdir, sizeof rdir, "%s/registry", kai_home()); mkdir(rdir, 0700);
    char fp[1200];
    snprintf(fp, sizeof fp, "%s/registry/pause-session-%s", kai_home(), session);
    if (minutes <= 0) { unlink(fp); return 0; }   /* resume */
    if (minutes > 24 * 60) minutes = 24 * 60;      /* cap at 1 day: a longer pause
                                                      is the wall switched off, so
                                                      use a 7-day grant instead */
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
