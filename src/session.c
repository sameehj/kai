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
#include <errno.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/file.h>
#include <signal.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

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

/* Phase B item 6: user-facing names are what is protected (Files = the storage
 * wall, Internet = the network wall), not the walls. */
const char *kai_enforcement_label(int storage_active, int network_active) {
    if (storage_active && network_active) return "Enforced: Files and Internet";
    if (network_active && !storage_active) return "Enforced: Internet only";
    if (storage_active && !network_active) return "Enforced: Files only";
    return "Seen only: Files and Internet are off";
}

static int id_ok(const char *id);
static int read_session(const char *path, kai_session *out);

/* Labels from the same measured levels as the headline (kai_wall_observed_level):
 * a wall covers sessions in Watch or Protect (>= 1); off / not running /
 * unverified (<= 0) does not. */
const char *kai_enforcement_from_levels(int files, int internet) {
    return kai_enforcement_label(files >= 1, internet >= 1);
}

/* ---- session activity (Agent Control: working / idle) ----
 * "Working" = the agent ran a command or a hook in the last 15 minutes. The
 * storage wall sees every exec in a session (a hook is an exec of `kai hook`)
 * and records the time per session and per working folder here, under the
 * registry (control store: an agent can't write its own activity). */
const char *kai_session_activity_dir(void) {
    static char buf[1200];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/registry/activity", kai_home());
    return buf;
}

int kai_session_working(long long last_active, long long now) {
    return last_active > 0 && now - last_active <= KAI_WORKING_WINDOW;
}

static cJSON *activity_load(const char *sid) {
    char path[1300];
    snprintf(path, sizeof path, "%s/%s.json", kai_session_activity_dir(), sid);
    size_t len = 0; char *txt = kai_read_file(path, 1 << 16, &len);
    cJSON *o = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    return o;
}

int kai_session_activity_touch(const char *sid, const char *workspace, long long now) {
    if (!id_ok(sid)) return -1;
    cJSON *o = activity_load(sid);
    if (!o) o = cJSON_CreateObject();
    if (!o) return -1;
    /* keep the latest time (events can be recorded out of order) */
    cJSON *l = cJSON_GetObjectItem(o, "last");
    long long prev = cJSON_IsNumber(l) ? (long long)l->valuedouble : 0;
    cJSON_DeleteItemFromObject(o, "last");
    cJSON_AddNumberToObject(o, "last", (double)(now > prev ? now : prev));
    cJSON *ws = cJSON_GetObjectItem(o, "ws");
    if (!cJSON_IsObject(ws)) { cJSON_DeleteItemFromObject(o, "ws"); ws = cJSON_AddObjectToObject(o, "ws"); }
    if (ws && workspace && *workspace) {
        cJSON *w = cJSON_GetObjectItem(ws, workspace);
        long long wprev = cJSON_IsNumber(w) ? (long long)w->valuedouble : 0;
        cJSON_DeleteItemFromObject(ws, workspace);
        if (cJSON_GetArraySize(ws) >= 32) cJSON_DeleteItemFromArray(ws, 0);   /* bounded */
        cJSON_AddNumberToObject(ws, workspace, (double)(now > wprev ? now : wprev));
    }
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;
    char path[1300], tmp[1400];
    mkdir(kai_home(), 0700);
    mkdir(kai_session_dir(), 0700);
    mkdir(kai_session_activity_dir(), 0700);
    snprintf(path, sizeof path, "%s/%s.json", kai_session_activity_dir(), sid);
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { free(js); return -1; }
    size_t len = strlen(js);
    int ok = fwrite(js, 1, len, f) == len;
    ok = (fclose(f) == 0) && ok;
    free(js);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

/* A tool call in progress: set on an allowed PreToolUse (since = when),
 * cleared (0) on PostToolUse. Stored in the session's activity record. */
int kai_session_inflight_set(const char *sid, long long since) {
    if (!id_ok(sid)) return -1;
    cJSON *o = activity_load(sid);
    if (!o) o = cJSON_CreateObject();
    if (!o) return -1;
    cJSON_DeleteItemFromObject(o, "inflight");
    if (since > 0) cJSON_AddNumberToObject(o, "inflight", (double)since);
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return -1;
    char path[1300], tmp[1400];
    mkdir(kai_home(), 0700);
    mkdir(kai_session_dir(), 0700);
    mkdir(kai_session_activity_dir(), 0700);
    snprintf(path, sizeof path, "%s/%s.json", kai_session_activity_dir(), sid);
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { free(js); return -1; }
    int ok = fputs(js, f) >= 0;
    ok = (fclose(f) == 0) && ok;
    free(js);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

int kai_session_busy(const char *sid, long long now) {
    if (!id_ok(sid)) return 0;
    cJSON *o = activity_load(sid);
    cJSON *i = o ? cJSON_GetObjectItem(o, "inflight") : NULL;
    long long since = cJSON_IsNumber(i) ? (long long)i->valuedouble : 0;
    cJSON_Delete(o);
    return since > 0 && now - since < 6 * 3600;   /* a crashed agent's call doesn't count forever */
}

long long kai_session_last_active(const char *sid, const char *workspace) {
    if (!id_ok(sid)) return 0;
    cJSON *o = activity_load(sid);
    if (!o) return 0;
    long long last = 0;
    if (!workspace) {
        cJSON *l = cJSON_GetObjectItem(o, "last");
        if (cJSON_IsNumber(l)) last = (long long)l->valuedouble;
    } else {
        size_t wl = strlen(workspace);
        cJSON *ws = cJSON_GetObjectItem(o, "ws"), *e = NULL;
        cJSON_ArrayForEach(e, ws) {
            const char *k = e->string;
            if (!k || !cJSON_IsNumber(e) || strncmp(k, workspace, wl) != 0 || (k[wl] && k[wl] != '/'))
                continue;
            if ((long long)e->valuedouble > last) last = (long long)e->valuedouble;
        }
    }
    cJSON_Delete(o);
    return last;
}

/* A "(delegated)" process (its responsible process is an agent) never owns a
 * session; remove the records older builds made for them. Returns how many. */
int kai_sessions_prune_delegated(void) {
    DIR *d = opendir(kai_session_dir());
    if (!d) return 0;
    int removed = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (e->d_name[0] == '.' || nl < 6 || strcmp(e->d_name + nl - 5, ".json")) continue;
        char path[1300];
        if (snprintf(path, sizeof path, "%s/%s", kai_session_dir(), e->d_name) >= (int)sizeof path) continue;
        kai_session s;
        if (read_session(path, &s) && strstr(s.agent, " (delegated)") && unlink(path) == 0) {
            char ap[1400];
            snprintf(ap, sizeof ap, "%s/%s.json", kai_session_activity_dir(), s.id);
            unlink(ap);
            removed++;
        }
    }
    closedir(d);
    return removed;
}

/* Phase B item 8: the ONE status sentence, shared by the popover, the Settings
 * sidebar, the menu-bar label and `kai status`. files/internet: 0 off (not
 * running or set off), 1 watch (log), 2 protect (block), from what the walls
 * REPORT, never the policy. agents < 0 = count unknown (no suffix). */
const char *kai_status_sentence(int files, int internet, int agents, int paused,
                                char *out, size_t n) {
    if (!out || !n) return "";
    if (paused) snprintf(out, n, "Kai is paused");
    /* Internet not verified: left out of the headline, which speaks for Files. */
    else if (internet < 0 && files <= 0) snprintf(out, n, "Files protection is off");
    else if (internet < 0 && files == 1) snprintf(out, n, "Files: watching only");
    else if (internet < 0 && agents > 0)
        snprintf(out, n, "Files protected \xC2\xB7 %d agent%s working", agents, agents == 1 ? "" : "s");
    else if (internet < 0) snprintf(out, n, "Files protected");
    else if (files == 0 && internet == 0) snprintf(out, n, "Not protected");
    else if (files == 0) snprintf(out, n, "Files protection is off");
    else if (internet == 0) snprintf(out, n, "Internet protection is off");
    else if (files == 1 && internet == 1) snprintf(out, n, "Watching only");
    else if (files == 1) snprintf(out, n, "Partly protected \xC2\xB7 Files is watching only");
    else if (internet == 1) snprintf(out, n, "Partly protected \xC2\xB7 Internet is watching only");
    else if (agents > 0)
        snprintf(out, n, "Protected \xC2\xB7 %d agent%s working", agents, agents == 1 ? "" : "s");
    else snprintf(out, n, "Protected");
    return out;
}

/* Fix 3: a wall heartbeat counts only if it can't have been forged by an agent
 * running as the user: owned by `owner` (root in production), not group- or
 * world-writable, written within 30 s, and naming `wall`. Returns 2 block,
 * 1 log, 0 off, -1 not verified (missing, stale, wrong owner/mode/wall). */
int kai_heartbeat_level(const char *path, const char *wall, uid_t owner) {
    struct stat st;
    if (!path || !wall || lstat(path, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    if (st.st_uid != owner || (st.st_mode & (S_IWGRP | S_IWOTH))) return -1;
    if ((long)(time(NULL) - st.st_mtime) > 30) return -1;
    size_t len = 0;
    char *txt = kai_read_file(path, 1 << 16, &len);
    cJSON *o = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    const char *w = o ? cJSON_GetStringValue(cJSON_GetObjectItem(o, "wall")) : NULL;
    const char *m = o ? cJSON_GetStringValue(cJSON_GetObjectItem(o, "mode")) : NULL;
    int lvl = -1;
    if (w && !strcmp(w, wall) && m)
        lvl = !strcmp(m, "block") ? 2 : (!strcmp(m, "log") || !strcmp(m, "warn")) ? 1 : 0;
    cJSON_Delete(o);
    return lvl;
}

/* Pause as a visible state. The pause marker is what the hooks read; the
 * storage wall's verified heartbeat lists what it has applied ("paused" for
 * the global pause, "paused_sessions" per session). Only both together are
 * KAI_PAUSE_ACTIVE; the marker alone is KAI_PAUSE_PENDING ("Pausing…"), so
 * the UI never shows a pause that isn't happening. sid NULL = global. */
int kai_pause_state_at(const char *heartbeat, uid_t owner, const char *sid, long long now) {
    int marker = sid ? kai_session_paused(sid, now) : kai_wall_paused("storage", now);
    if (!marker) return KAI_PAUSE_NONE;
    if (kai_heartbeat_level(heartbeat, "storage", owner) < 0) return KAI_PAUSE_PENDING;
    size_t len = 0;
    char *txt = kai_read_file(heartbeat, 1 << 16, &len);
    cJSON *o = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    int applied = 0;
    if (o && !sid) applied = cJSON_IsTrue(cJSON_GetObjectItem(o, "paused"));
    if (o && sid) {
        cJSON *e = NULL;
        cJSON_ArrayForEach(e, cJSON_GetObjectItem(o, "paused_sessions"))
            if (cJSON_IsString(e) && !strcmp(e->valuestring, sid)) { applied = 1; break; }
    }
    cJSON_Delete(o);
    return applied ? KAI_PAUSE_ACTIVE : KAI_PAUSE_PENDING;
}

/* Is anything paused right now (Kai as a whole, or any session)? For the
 * menu-bar icon. Reads the pause markers (registry/pause-session-<id>). */
int kai_any_pause_active(long long now) {
    if (kai_wall_paused("storage", now)) return 1;
    DIR *d = opendir(kai_session_dir());
    if (!d) return 0;
    struct dirent *e; int any = 0;
    while (!any && (e = readdir(d)))
        if (!strncmp(e->d_name, "pause-session-", 14) && kai_session_paused(e->d_name + 14, now)) any = 1;
    closedir(d);
    return any;
}

/* One Kai: the release instance - the only one that hosts the control
 * service (the sole writer of policy and permissions) - is the app installed
 * at /Applications/Kai.app with the release Team ID. Any other copy (a build/
 * folder, an old build an agent launched) is a dev copy. */
int kai_app_is_release(const char *bundle_path, const char *team) {
    return bundle_path && team && !strcmp(bundle_path, "/Applications/Kai.app") &&
           !strcmp(team, KAI_RELEASE_TEAM);
}

/* Backstop to the bundle-id handover: an exclusive lock held for the app's
 * life. Returns the fd to keep open, or -1 if another Kai holds it or the lock
 * can't be opened (a copy that can't reach Kai's home must not run). */
int kai_app_lock_acquire(const char *path) {
    if (!path) return -1;
    char dir[1200];
    kai_strlcpy(dir, path, sizeof dir);
    char *slash = strrchr(dir, '/');
    if (slash) { *slash = '\0'; mkdir(dir, 0700); }
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}

/* Who may open the approval key (the grant-signing secret). The storage wall
 * asks this for every Kai-signed process. Exact signing identifier + Team ID +
 * where it runs from:
 *   the installed app (/Applications/Kai.app)         read + write
 *   the network extension (installed system extension) read only - it verifies
 *                                                      endpoint grants
 *   anything else, incl. the `kai` CLI an agent can run  denied */
int kai_approval_key_access(const char *signing_id, const char *team, const char *exe, int write) {
    if (!signing_id || !team || !exe || strcmp(team, KAI_RELEASE_TEAM) != 0) return 0;
    if (!strcmp(signing_id, "io.github.sameehj.kai"))
        return !strcmp(exe, "/Applications/Kai.app/Contents/MacOS/Kai");
    if (!strcmp(signing_id, "io.github.sameehj.kai.network"))
        return !write && !strncmp(exe, "/Library/SystemExtensions/", 26);
    return 0;
}

int kai_component_may_touch(const char *signing_id, int under_agent, const char *rule) {
    if (!rule || !*rule) return 1;                       /* not protected */
    if (kai_rule_is_builtin(rule)) return 1;             /* Kai's home, agent hook configs */
    return signing_id && !strcmp(signing_id, "kai") && !under_agent;   /* the user's own CLI */
}

int kai_pause_state(const char *sid, long long now) {
    return kai_pause_state_at("/tmp/kai-storage-health.json", 0, sid, now);
}

/* The network extension is sandboxed: it can't write /tmp, so its heartbeat
 * goes in the console user's copy of the Kai app-group container. */
const char *kai_network_heartbeat_path(void) {
    static char path[1024];
    char *h = kai_expand_home("~/Library/Group Containers/" KAI_APP_GROUP "/network-health.json");
    kai_strlcpy(path, h, sizeof path);
    free(h);
    return path;
}

/* A wall's VERIFIED level (root-owned heartbeat): 2 block, 1 log, 0 off, -1
 * not verified. Callers never infer it from the policy: Files unverified is
 * not running (off); Internet unverified is shown as "not verified". */
int kai_wall_observed_level(const char *wall) {
    if (wall && !strcmp(wall, "network")) return kai_heartbeat_level(kai_network_heartbeat_path(), "network", 0);
    return kai_heartbeat_level("/tmp/kai-storage-health.json", "storage", 0);
}

void kai_sha256(const void *data, size_t n, uint8_t out[32]); /* src/sha256.c */

/* B3: the one word Settings shows for a wall, from what macOS says about the
 * extension (os) and the measured heartbeat level (-1 none/unverified, 0 off,
 * 1 watch, 2 protect). Never "protecting" without a verified heartbeat. */
const char *kai_wall_state_word(int os, int level) {
    switch (os) {
    case KAI_WALL_OS_NOT_INSTALLED: return "not installed";
    case KAI_WALL_OS_OFF:           return "off";
    case KAI_WALL_OS_STARTING:      return "starting";
    case KAI_WALL_OS_FAILED:        return "unhealthy";
    default:
        return level == 2 ? "protecting" : level == 1 ? "watching" : level == 0 ? "off" : "unhealthy";
    }
}

/* B4: which policy a wall has loaded - the first 12 hex digits of the SHA-256
 * of the policy file, or "built-in" when there is none. */
void kai_policy_fingerprint(char *out, size_t n) {
    size_t len = 0;
    char *txt = kai_read_file(kai_policy_file(), 4u << 20, &len);
    if (!txt) { kai_strlcpy(out, "built-in", n); return; }
    uint8_t h[32];
    kai_sha256(txt, len, h);
    free(txt);
    snprintf(out, n, "%02x%02x%02x%02x%02x%02x", h[0], h[1], h[2], h[3], h[4], h[5]);
}

/* B4: a field from a wall's VERIFIED heartbeat (same checks as the level), as
 * text. 1 found, 0 no verified heartbeat or no such field. */
int kai_heartbeat_field(const char *wall, const char *key, char *out, size_t n) {
    if (n) out[0] = '\0';
    int net = wall && !strcmp(wall, "network");
    const char *path = net ? kai_network_heartbeat_path() : "/tmp/kai-storage-health.json";
    if (kai_heartbeat_level(path, net ? "network" : "storage", 0) < 0) return 0;
    size_t len = 0;
    char *txt = kai_read_file(path, 1 << 16, &len);
    cJSON *o = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    const cJSON *v = o ? cJSON_GetObjectItem(o, key) : NULL;
    int ok = 1;
    if (cJSON_IsString(v)) kai_strlcpy(out, v->valuestring, n);
    else if (cJSON_IsNumber(v)) snprintf(out, n, "%lld", (long long)v->valuedouble);
    else if (cJSON_IsBool(v)) kai_strlcpy(out, cJSON_IsTrue(v) ? "true" : "false", n);
    else ok = 0;
    cJSON_Delete(o);
    return ok;
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

/* Live fix: a registry record is active only while its root process runs and
 * is not a newer process that reused the pid (it started after the session was
 * recorded). The wall loses its in-memory sessions when it restarts, so records
 * it never ended pile up as "active" otherwise. */
int kai_session_live(const kai_session *s) {
    if (!s || s->ended_utc || s->root_pid <= 0) return 0;
    if (kill(s->root_pid, 0) != 0 && errno == ESRCH) return 0;
#ifdef __APPLE__
    struct proc_bsdinfo bi;
    if (s->started_utc > 0 &&
        proc_pidinfo(s->root_pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == (int)sizeof bi &&
        (long long)bi.pbi_start_tvsec > s->started_utc + 1)
        return 0;                       /* pid reused by a newer process */
#endif
    return 1;
}

/* May `es` take over an agent session id bound to the earlier `prev`? Only
 * when prev is a known record that has ended / is no longer live, or has the
 * same agent root (the wall restarted and re-minted it). Unknown prev: no. */
static int rebind_ok(const char *prev, const char *es) {
    kai_session a, b;
    if (!kai_session_get(prev, &a)) return 0;
    if (!kai_session_live(&a)) return 1;
    return kai_session_get(es, &b) && a.root_pid > 0 && a.root_pid == b.root_pid;
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
            if (as && strcmp(as, agent_session) == 0 && strcmp(esid, es) != 0 &&
                !rebind_ok(esid, es))
                clash = 1;
            cJSON_Delete(o);
        }
    }
    closedir(d);
    return clash;
}

/* A session's topic is the first real sentence of the user's first prompt:
 * pasted-content placeholders and their bodies, tags such as <system-reminder>
 * or <command-name>, "[Pasted text #1 +40 lines]" / "[Image #1]" lines, code
 * fences and markdown emphasis are skipped. Empty when nothing is left (the
 * app then shows the project name). */
void kai_topic_clean(const char *raw, char *out, size_t n) {
    if (n) out[0] = '\0';
    if (!raw || !n) return;
    char *copy = strdup(raw);
    if (!copy) return;
    int skip_block = 0;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t' || *line == '\r') line++;
        size_t L = strlen(line);
        while (L && (line[L - 1] == ' ' || line[L - 1] == '\r' || line[L - 1] == '\t')) line[--L] = '\0';
        if (skip_block) {                                  /* inside <pasted_content> ... </...> */
            if (strstr(line, "pasted_content>") || strstr(line, "/pasted")) skip_block = 0;
            continue;
        }
        if (!L) continue;
        if (line[0] == '<') {
            int opens_paste = strstr(line, "pasted_content") && !strstr(line, "/pasted_content") &&
                              !strstr(line + 1, "</");
            if (opens_paste && !strstr(line, "/>")) skip_block = 1;
            continue;                                      /* markup, never a topic */
        }
        if (line[0] == '[' && (strstr(line, "Pasted") || strstr(line, "Image #") || strstr(line, "pasted"))) continue;
        if (!strncmp(line, "```", 3)) continue;
        /* the first real line: strip emphasis, keep the first sentence */
        size_t o = 0;
        for (size_t i = 0; line[i] && o + 1 < n; i++) {
            if (line[i] == '*' || line[i] == '`' || (line[i] == '_' && line[i + 1] == '_')) {
                if (line[i] == '_') i++;
                continue;
            }
            out[o++] = line[i];
            if ((line[i] == '.' || line[i] == '?' || line[i] == '!') && line[i + 1] == ' ') break;
        }
        out[o] = '\0';
        break;
    }
    free(copy);
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
    char topic[128] = "", first[512];
    kai_topic_clean(raw_topic, first, sizeof first);
    raw_topic = first;
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
