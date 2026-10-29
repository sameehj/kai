/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Machine-readable status and safe policy editing. Used by the menu-bar app
 * and handy from scripts:
 *
 *   kai status --json
 *   kai policy path
 *   kai policy show [--json]
 *   kai policy set <switch> <value>
 *   kai policy add protect|allow|egress_allow <path-or-host>
 *   kai policy add term <action> <text...>
 *   kai policy add rule <name> <action> <regex...>
 *   kai policy remove protect|allow <path>
 *   kai policy remove term <text...>
 *   kai policy remove rule <name>
 *
 * Edits keep the file's comments and layout, are validated by parsing the
 * result before anything is written, and replace the file atomically.
 */
/* Build guard: the policy test seam (KAI_TEST_DIRECT_POLICY - lets the throwaway
 * tests/cli/kai-test binary write policy directly and skips the pending-hold)
 * must never reach a shipped build. Product builds define KAI_PRODUCT_BUILD. */
#if defined(KAI_PRODUCT_BUILD) && defined(KAI_TEST_DIRECT_POLICY)
#error "KAI_TEST_DIRECT_POLICY must never be compiled into a product build"
#endif
#include "cJSON.h"
#include "internal.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---------- small helpers ---------- */

static int hook_command_present(const cJSON *node, const char *needle) {
    if (!node) return 0;
    if (cJSON_IsObject(node)) {
        const cJSON *command = cJSON_GetObjectItemCaseSensitive(node, "command");
        if (cJSON_IsString(command) && command->valuestring &&
            strstr(command->valuestring, needle)) return 1;
    }
    if (cJSON_IsObject(node) || cJSON_IsArray(node)) {
        for (const cJSON *child = node->child; child; child = child->next) {
            if (hook_command_present(child, needle)) return 1;
        }
    }
    return 0;
}

static int agent_installed(const char *rel, const char *needle, int *detected) {
    char *path = kai_expand_home(rel);
    size_t n;
    char *s = kai_read_file(path, 4 * 1024 * 1024, &n);
    cJSON *root = s ? cJSON_Parse(s) : NULL;
    const cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    int on = hook_command_present(hooks, needle);
    cJSON_Delete(root);
    free(s);
    if (detected) {
        /* the agent's config directory exists = the agent is probably used here */
        char *slash = strrchr(path, '/');
        if (slash) *slash = '\0';
        struct stat st;
        *detected = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    }
    free(path);
    return on;
}

/* Exposed for `kai status` / `kai doctor` (status.c). */
int kai_agent_hooks_installed(const char *rel, const char *needle, int *detected) {
    return agent_installed(rel, needle, detected);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static void print_json(cJSON *o) {
    char *s = cJSON_Print(o);
    if (s) printf("%s\n", s);
    free(s);
    cJSON_Delete(o);
}

/* ---------- kai status --json ---------- */

static const char *status_storage_mode_name(const kai_policy *p) {
    if (!p) return "unknown";
    switch (kai_policy_storage_mode(p)) {
        case KAI_STORAGE_BLOCK: return "block";
        case KAI_STORAGE_LOG:   return "log";
        default:                return "off";
    }
}
static const char *status_egress_mode_name(const kai_policy *p) {
    if (!p) return "unknown";
    switch (kai_policy_egress_mode(p)) {
        case KAI_EGRESS_BLOCK: return "block";
        case KAI_EGRESS_LOG:   return "log";
        default:               return "off";
    }
}

/* Read an extension's health snapshot if it exists and is fresh (written within
 * max_age_sec); else NULL (not observed running). Caller owns the returned node. */
static cJSON *status_read_health(const char *path, long max_age_sec) {
    struct stat st;
    if (stat(path, &st) != 0) return NULL;
    if ((long)(time(NULL) - st.st_mtime) > max_age_sec) return NULL; /* stale */
    size_t len = 0;
    char *txt = kai_read_file(path, 1 << 16, &len);
    if (!txt) return NULL;
    cJSON *o = cJSON_Parse(txt);
    free(txt);
    return o;
}

int kai_cmd_status_json(void) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "version", KAI_VERSION);
    cJSON_AddStringToObject(o, "exe", kai_exe_path());
    cJSON_AddStringToObject(o, "home", kai_home());

    char err[256] = "";
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    cJSON *pol = cJSON_AddObjectToObject(o, "policy");
    cJSON_AddBoolToObject(pol, "ok", p != NULL);
    cJSON_AddStringToObject(pol, "source", p ? kai_policy_source(p) : "");
    cJSON_AddStringToObject(pol, "file", kai_policy_file());
    cJSON_AddBoolToObject(pol, "file_exists", file_exists(kai_policy_file()));
    cJSON_AddStringToObject(pol, "error", p ? "" : err);
    kai_policy_free(p);

    char *codex = kai_codex_hooks_path();
    const struct { const char *name, *rel, *needle; } agents[] = {
        {"claude", "~/.claude/settings.json", "hook claude"},
        {"cursor", "~/.cursor/hooks.json", "hook cursor"},
        {"codex", codex, "hook codex"},
    };
    for (size_t i = 0; i < sizeof agents / sizeof agents[0]; i++) {
        int detected = 0;
        int on = agent_installed(agents[i].rel, agents[i].needle, &detected);
        cJSON *a = cJSON_AddObjectToObject(o, agents[i].name);
        cJSON_AddBoolToObject(a, "installed", on);
        cJSON_AddBoolToObject(a, "detected", detected);
        if (on) { /* installed isn't working: run what the agent would run */
            kai_health h;
            kai_health_agent(agents[i].name, agents[i].rel, &h);
            cJSON_AddBoolToObject(a, "working", h.ok);
            cJSON_AddStringToObject(a, "problem", h.problem);
        }
        char *cfg = kai_expand_home(agents[i].rel);
        cJSON_AddStringToObject(a, "config", cfg);
        free(cfg);
    }
    free(codex);
    {
        int detected = 0;
        int on = kai_browser_installed(&detected);
        cJSON *b = cJSON_AddObjectToObject(o, "chrome");
        cJSON_AddBoolToObject(b, "installed", on);
        cJSON_AddBoolToObject(b, "detected", detected);
        const char *ext = kai_browser_ext_dir();
        cJSON_AddStringToObject(b, "config", ext ? ext : "");
        cJSON_AddBoolToObject(b, "extension_loaded", kai_browser_extension_loaded());
        if (on) {
            char *exe = kai_browser_host_exe();
            kai_health h;
            kai_health_chrome(exe, &h);
            cJSON_AddBoolToObject(b, "working", h.ok);
            cJSON_AddStringToObject(b, "problem", h.problem);
            free(exe);
        }
    }

    cJSON *au = cJSON_AddObjectToObject(o, "audit");
    cJSON_AddStringToObject(au, "path", kai_audit_path());
    int nl = 0;
    char verr[256] = "";
    int exists = file_exists(kai_audit_path());
    int intact = exists ? kai_audit_verify(NULL, &nl, verr, sizeof verr) == 0 : 1;
    cJSON_AddNumberToObject(au, "records", nl);
    cJSON_AddBoolToObject(au, "intact", intact);
    cJSON_AddStringToObject(au, "error", intact ? "" : verr);

    /* Walls: CONFIGURED (from policy) vs OBSERVED (from each extension's health
     * snapshot). A toggle saying "on" proves nothing; the observed side proves
     * the extension is actually running, in which mode, and at which grant
     * generation. A stale/absent snapshot means not observed running. (#18) */
    cJSON *w = cJSON_AddObjectToObject(o, "walls");
    cJSON *cfg = cJSON_AddObjectToObject(w, "configured");
    cJSON_AddStringToObject(cfg, "storage", status_storage_mode_name(p));
    cJSON_AddStringToObject(cfg, "network", status_egress_mode_name(p));
    cJSON *obs = cJSON_AddObjectToObject(w, "observed");
    cJSON *sh = status_read_health("/tmp/kai-storage-health.json", 30);
    cJSON *so = cJSON_AddObjectToObject(obs, "storage");
    cJSON_AddBoolToObject(so, "running", sh != NULL);
    cJSON_AddBoolToObject(so, "verified", kai_wall_observed_level("storage") >= 0);
    if (sh) cJSON_AddItemToObject(so, "health", sh);
    cJSON *nh = status_read_health(kai_network_heartbeat_path(), 30);
    cJSON *no = cJSON_AddObjectToObject(obs, "network");
    cJSON_AddBoolToObject(no, "running", nh != NULL);
    cJSON_AddBoolToObject(no, "verified", kai_wall_observed_level("network") >= 0);
    if (nh) cJSON_AddItemToObject(no, "health", nh);

    print_json(o);
    return 0;
}

/* ---------- kai agents (S2): agent inventory ---------- */

int kai_cmd_agents(int argc, char **argv) {
    int json = argc > 0 && strcmp(argv[0], "--json") == 0;
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    kai_session *sess = NULL; int nsess = 0;
    kai_sessions_load(&sess, &nsess);
    char *codex = kai_codex_hooks_path();
    const struct { const char *name, *rel, *needle; } agents[] = {
        {"claude", "~/.claude/settings.json", "hook claude"},
        {"cursor", "~/.cursor/hooks.json", "hook cursor"},
        {"codex", codex, "hook codex"},
    };
    cJSON *arr = json ? cJSON_CreateArray() : NULL;
    if (!json)
        printf("%-8s %-10s %-15s %-10s %s\n", "agent", "hooks", "walls", "sessions", "detail");
    for (size_t i = 0; i < sizeof agents / sizeof agents[0]; i++) {
        int detected = 0;
        int on = agent_installed(agents[i].rel, agents[i].needle, &detected);
        kai_health h; h.ok = 0; h.problem[0] = '\0';
        if (on) kai_health_agent(agents[i].name, agents[i].rel, &h);
        const char *hooks = !on ? (detected ? "missing" : "not found")
                                : (h.ok ? "installed" : "failing");
        int recog = kai_agent_wall_recognized(p, agents[i].name);
        int active = 0;
        for (int k = 0; k < nsess; k++)
            if (sess[k].ended_utc == 0 &&
                strncmp(sess[k].agent, agents[i].name, strlen(agents[i].name)) == 0) active++;
        char detail[320];
        if (on && !h.ok) kai_strlcpy(detail, h.problem, sizeof detail);
        else if (!on) snprintf(detail, sizeof detail, "not protected; run: kai install %s", agents[i].name);
        else detail[0] = '\0';
        if (json) {
            cJSON *a = cJSON_CreateObject();
            cJSON_AddStringToObject(a, "name", agents[i].name);
            cJSON_AddBoolToObject(a, "installed", on);
            cJSON_AddBoolToObject(a, "detected", detected);
            cJSON_AddStringToObject(a, "hooks", hooks);
            if (detail[0]) cJSON_AddStringToObject(a, "detail", detail);
            cJSON_AddBoolToObject(a, "wall_recognized", recog);
            cJSON_AddNumberToObject(a, "active_sessions", active);
            cJSON_AddItemToArray(arr, a);
        } else {
            char ses[16]; snprintf(ses, sizeof ses, "%d active", active);
            printf("%-8s %-10s %-15s %-10s %s\n", agents[i].name, hooks,
                   recog ? "recognized" : "not recognized", ses, detail);
        }
    }
    /* User-defined agents the walls recognize but Kai installs no hooks for. */
    if (p) {
        for (int i = 0; i < p->nagents; i++) {
            const char *nm = p->agents[i].name;
            if (!strcmp(nm, "claude") || !strcmp(nm, "cursor") || !strcmp(nm, "codex")) continue;
            /* de-dupe repeated names (an agent may have several rules) */
            int seen = 0;
            for (int j = 0; j < i; j++) if (!strcmp(p->agents[j].name, nm)) { seen = 1; break; }
            if (seen) continue;
            int active = 0;
            for (int k = 0; k < nsess; k++)
                if (sess[k].ended_utc == 0 && strncmp(sess[k].agent, nm, strlen(nm)) == 0) active++;
            if (json) {
                cJSON *a = cJSON_CreateObject();
                cJSON_AddStringToObject(a, "name", nm);
                cJSON_AddStringToObject(a, "hooks", "n/a");
                cJSON_AddBoolToObject(a, "wall_recognized", 1);
                cJSON_AddNumberToObject(a, "active_sessions", active);
                cJSON_AddItemToArray(arr, a);
            } else {
                char ses[16]; snprintf(ses, sizeof ses, "%d active", active);
                printf("%-8s %-10s %-15s %-10s %s\n", nm, "n/a", "recognized", ses,
                       "recognized by the network wall (no Kai hooks)");
            }
        }
    }
    /* Discovery suggestions (item 5): unrecognized programs that talked to a
     * model API. Shown as "looks like an agent — protect it?"; never auto-added. */
    kai_discovery *disc = NULL; int ndisc = 0;
    kai_discovery_load(&disc, &ndisc);
    for (int i = 0; i < ndisc; i++) {
        const char *base = strrchr(disc[i].exe, '/');
        base = base ? base + 1 : disc[i].exe;
        if (json) {
            cJSON *a = cJSON_CreateObject();
            cJSON_AddStringToObject(a, "name", base);
            cJSON_AddStringToObject(a, "suggestion", "looks like an agent");
            cJSON_AddStringToObject(a, "exe", disc[i].exe);
            cJSON_AddStringToObject(a, "saw_host", disc[i].host);
            cJSON_AddItemToArray(arr, a);
        } else {
            if (i == 0) printf("\nLooks like an agent (talked to a model API; not protected):\n");
            printf("  %-12s %s  -> protect: kai policy add agent %s exe '%s'\n",
                   base, disc[i].host, base, disc[i].exe);
        }
    }
    free(disc);
    /* AI chats (item 3): chat sites the Kai browser extension reports as open.
     * Browser extension · walls don't apply. Site only; no URL, no chat text. */
    kai_chat *chats = NULL; int nchats = 0;
    kai_chat_load(&chats, &nchats);
    for (int i = 0; i < nchats; i++) {
        if (json) {
            cJSON *a = cJSON_CreateObject();
            cJSON_AddStringToObject(a, "name", chats[i].site);
            cJSON_AddStringToObject(a, "kind", "ai-chat");
            cJSON_AddStringToObject(a, "source", "browser extension");
            cJSON_AddStringToObject(a, "coverage", "Files and Internet protection don't apply");
            cJSON_AddNumberToObject(a, "open_tabs", chats[i].open_tabs);
            cJSON_AddNumberToObject(a, "redactions", chats[i].redactions);
            cJSON_AddNumberToObject(a, "overrides", chats[i].overrides);
            cJSON_AddItemToArray(arr, a);
        } else {
            if (i == 0) printf("\nChats (browser extension - Files and Internet protection don't apply):\n");
            printf("  %-22s %d open, %d redacted, %d sent anyway\n",
                   chats[i].site, chats[i].open_tabs, chats[i].redactions, chats[i].overrides);
        }
    }
    free(chats);
    free(codex); kai_policy_free(p); free(sess);
    if (json) print_json(arr);
    return 0;
}

/* ---------- policy file as editable lines ---------- */

typedef struct {
    char **v;
    int n, cap;
} lines_t;

static void lines_push(lines_t *L, char *s) {
    if (L->n >= L->cap) {
        int nc = L->cap ? L->cap * 2 : 64;
        char **nv = realloc(L->v, (size_t)nc * sizeof *nv);
        if (!nv) { free(s); return; }
        L->v = nv;
        L->cap = nc;
    }
    L->v[L->n++] = s;
}

static void lines_insert(lines_t *L, int at, char *s) {
    int before = L->n;
    lines_push(L, s);
    if (L->n == before) return; /* push failed */
    memmove(&L->v[at + 1], &L->v[at], (size_t)(L->n - 1 - at) * sizeof *L->v);
    L->v[at] = s;
}

static void lines_remove(lines_t *L, int at) {
    free(L->v[at]);
    memmove(&L->v[at], &L->v[at + 1], (size_t)(L->n - at - 1) * sizeof *L->v);
    L->n--;
}

static void lines_free(lines_t *L) {
    for (int i = 0; i < L->n; i++) free(L->v[i]);
    free(L->v);
    memset(L, 0, sizeof *L);
}

/* Load the policy file, or the built-in defaults if there is none yet. */
static int lines_load(lines_t *L) {
    memset(L, 0, sizeof *L);
    size_t n;
    char *txt = kai_read_file(kai_policy_file(), 4000000, &n);
    if (!txt) {
        if (file_exists(kai_policy_file())) return -1;
        txt = strdup(kai_default_policy());
        if (!txt) return -1;
    }
    char *s = txt;
    while (*s) {
        char *e = strchr(s, '\n');
        size_t len = e ? (size_t)(e - s) : strlen(s);
        char *line = malloc(len + 1);
        if (!line) break;
        memcpy(line, s, len);
        line[len] = '\0';
        lines_push(L, line);
        if (!e) break;
        s = e + 1;
    }
    free(txt);
    return 0;
}

static char *lines_join(const lines_t *L) {
    sb_t b;
    sb_init(&b);
    for (int i = 0; i < L->n; i++) { sb_adds(&b, L->v[i]); sb_adds(&b, "\n"); }
    return sb_take(&b);
}

/* Validate the policy text these lines would produce. Returns owned text on
 * success (caller frees), NULL after printing why it was rejected. */
static char *lines_validate(const lines_t *L) {
    char *txt = lines_join(L);
    char err[256];
    kai_policy *p = kai_policy_from_string(txt, err, sizeof err);
    if (!p) {
        fprintf(stderr, "kai policy: change rejected, it would break the policy: %s\n", err);
        free(txt);
        return NULL;
    }
    kai_policy_free(p);
    return txt;
}

/* Write policy text to `path` via temp file + rename so a reader never sees
 * half a policy. `path` NULL = the live policy file. */
static int policy_write_text(const char *txt, const char *path) {
    if (!path) { mkdir(kai_home(), 0700); path = kai_policy_file(); }
    char tmp[1400];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { fprintf(stderr, "kai policy: cannot write %s\n", tmp); return 1; }
    chmod(tmp, 0600);
    size_t len = strlen(txt);
    int ok = fwrite(txt, 1, len, f) == len;
    ok = (fflush(f) == 0) && ok;
    ok = (fsync(fileno(f)) == 0) && ok;
    ok = (fclose(f) == 0) && ok;
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        fprintf(stderr, "kai policy: cannot write %s\n", path);
        return 1;
    }
    if (!strcmp(path, kai_policy_file())) kai_policy_record_fingerprint();   /* A.6b */
    return 0;
}


/* Split a line into directive and the span of its first argument. Returns 0
 * for blank/comment lines. */
static int line_parts(const char *line, char *dir, size_t dirlen,
                      const char **arg, size_t *arglen) {
    const char *s = line;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s || *s == '#') return 0;
    const char *d = s;
    while (*s && *s != ' ' && *s != '\t') s++;
    size_t dl = (size_t)(s - d);
    if (dl >= dirlen) dl = dirlen - 1;
    memcpy(dir, d, dl);
    dir[dl] = '\0';
    while (*s == ' ' || *s == '\t') s++;
    *arg = s;
    const char *e = s;
    while (*e && *e != ' ' && *e != '\t') e++;
    *arglen = (size_t)(e - s);
    return 1;
}

static char *trimmed(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    size_t n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r')) n--;
    char *r = malloc(n + 1);
    if (r) { memcpy(r, s, n); r[n] = '\0'; }
    return r;
}

/* An action token: block | redact | warn | replace:"text". Spans to the
 * closing quote for replace. Returns a pointer just past it. */
static const char *action_end(const char *s) {
    if (strncmp(s, "replace:\"", 9) == 0) {
        const char *q = strchr(s + 9, '"');
        return q ? q + 1 : s + strlen(s);
    }
    while (*s && *s != ' ' && *s != '\t') s++;
    return s;
}

/* Fill action and replacement JSON fields from an action token. */
static void add_action_json(cJSON *o, const char *tok, size_t len) {
    if (len >= 8 && strncmp(tok, "replace:", 8) == 0) {
        const char *v = tok + 8;
        size_t vl = len - 8;
        if (vl && *v == '"') { v++; vl--; }
        if (vl && v[vl - 1] == '"') vl--;
        char *r = malloc(vl + 1);
        if (r) { memcpy(r, v, vl); r[vl] = '\0'; }
        cJSON_AddStringToObject(o, "action", "replace");
        cJSON_AddStringToObject(o, "replacement", r ? r : "");
        free(r);
        return;
    }
    char a[32];
    size_t al = len < sizeof a - 1 ? len : sizeof a - 1;
    memcpy(a, tok, al);
    a[al] = '\0';
    cJSON_AddStringToObject(o, "action", a);
}

/* ---------- switches ---------- */

static const struct {
    const char *key, *def;
    const char *values[5];
} SWITCHES[] = {
    {"secrets", "redact", {"redact", "block", "warn", "off", NULL}},
    {"on_prompt_secret", "block", {"block", "warn", NULL}},
    {"on_file_secret", "ask", {"ask", "block", "warn", NULL}},
    {"on_upload", "block", {"block", "ask", "warn", NULL}},
    {"on_fetch", "allow", {"allow", "block", NULL}},
    {"injection", "warn", {"warn", "off", NULL}},
    {"max_scan_bytes", "2000000", {NULL}},
    {"egress", "log", {"log", "block", "off", NULL}},
    {"storage", "off", {"off", "log", "block", NULL}},
    {"gateway_port", "8787", {NULL}},
    {"audit_context", "on", {"on", "off", NULL}},
};
#define NSWITCHES (int)(sizeof SWITCHES / sizeof SWITCHES[0])

static int switch_index(const char *key) {
    for (int i = 0; i < NSWITCHES; i++)
        if (strcmp(SWITCHES[i].key, key) == 0) return i;
    return -1;
}

static int switch_value_ok(int i, const char *val) {
    if (!SWITCHES[i].values[0]) { /* numeric */
        char *end;
        long v = strtol(val, &end, 10);
        return *val && !*end && v > 0;
    }
    for (int j = 0; SWITCHES[i].values[j]; j++)
        if (strcmp(SWITCHES[i].values[j], val) == 0) return 1;
    return 0;
}

static void switch_usage(void) {
    fprintf(stderr, "switches:\n");
    for (int i = 0; i < NSWITCHES; i++) {
        fprintf(stderr, "  %-17s ", SWITCHES[i].key);
        if (!SWITCHES[i].values[0]) fprintf(stderr, "<positive number>");
        for (int j = 0; SWITCHES[i].values[j]; j++)
            fprintf(stderr, "%s%s", j ? " | " : "", SWITCHES[i].values[j]);
        fprintf(stderr, "\n");
    }
}

/* ---------- kai policy show ---------- */

static int policy_show(int json) {
    lines_t L;
    if (lines_load(&L) != 0) {
        fprintf(stderr, "kai policy: cannot read %s\n", kai_policy_file());
        return 1;
    }
    if (!json) {
        char *t = lines_join(&L);
        fputs(t, stdout);
        free(t);
        lines_free(&L);
        return 0;
    }

    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "file", kai_policy_file());
    cJSON_AddBoolToObject(o, "exists", file_exists(kai_policy_file()));
    char err[256] = "";
    char *txt = lines_join(&L);
    kai_policy *p = kai_policy_from_string(txt, err, sizeof err);
    free(txt);
    cJSON_AddBoolToObject(o, "ok", p != NULL);
    cJSON_AddStringToObject(o, "error", p ? "" : err);
    kai_policy_free(p);

    const char *vals[NSWITCHES];
    for (int i = 0; i < NSWITCHES; i++) vals[i] = SWITCHES[i].def;
    char valbuf[NSWITCHES][64];

    cJSON *protect = cJSON_CreateArray(), *allow = cJSON_CreateArray();
    cJSON *terms = cJSON_CreateArray(), *rules = cJSON_CreateArray();
    cJSON *egress = cJSON_CreateArray();
    cJSON *channels = cJSON_CreateArray();
    cJSON *agents = cJSON_CreateArray();
    cJSON *exempt = cJSON_CreateArray();
    for (int i = 0; i < L.n; i++) {
        char dir[32];
        const char *arg;
        size_t al;
        if (!line_parts(L.v[i], dir, sizeof dir, &arg, &al) || !al) continue;
        int si = switch_index(dir);
        if (si >= 0) {
            size_t n = al < 63 ? al : 63;
            memcpy(valbuf[si], arg, n);
            valbuf[si][n] = '\0';
            vals[si] = valbuf[si];
        } else if (strcmp(dir, "channel") == 0) {
            char *v = malloc(al + 1);
            if (!v) continue;
            memcpy(v, arg, al); v[al] = '\0';
            cJSON_AddItemToArray(channels, cJSON_CreateString(v));
            free(v);
        } else if (strcmp(dir, "protect") == 0 || strcmp(dir, "allow") == 0 ||
                   strcmp(dir, "egress_allow") == 0) {
            char *v = malloc(al + 1);
            if (!v) continue;
            memcpy(v, arg, al);
            v[al] = '\0';
            cJSON *list = dir[0] == 'p' ? protect : (dir[0] == 'a' ? allow : egress);
            cJSON_AddItemToArray(list, cJSON_CreateString(v));
            free(v);
        } else if (strcmp(dir, "term") == 0) {
            const char *ae = action_end(arg);
            char *text = trimmed(ae);
            if (!text || !*text) { free(text); continue; }
            cJSON *t = cJSON_CreateObject();
            add_action_json(t, arg, (size_t)(ae - arg));
            cJSON_AddStringToObject(t, "text", text);
            cJSON_AddItemToArray(terms, t);
            free(text);
        } else if (strcmp(dir, "rule") == 0) {
            char name[KAI_NAME_MAX];
            size_t nl = al < sizeof name - 1 ? al : sizeof name - 1;
            memcpy(name, arg, nl);
            name[nl] = '\0';
            const char *s = arg + al;
            while (*s == ' ' || *s == '\t') s++;
            const char *ae = action_end(s);
            char *pat = trimmed(ae);
            if (!pat || !*pat) { free(pat); continue; }
            cJSON *r = cJSON_CreateObject();
            cJSON_AddStringToObject(r, "name", name);
            add_action_json(r, s, (size_t)(ae - s));
            cJSON_AddStringToObject(r, "pattern", pat);
            cJSON_AddItemToArray(rules, r);
            free(pat);
        } else if (strcmp(dir, "exempt") == 0) {
            /* exempt <rule> <glob...> */
            char name[KAI_NAME_MAX];
            size_t nl = al < sizeof name - 1 ? al : sizeof name - 1;
            memcpy(name, arg, nl);
            name[nl] = '\0';
            char *pat = trimmed(arg + al);
            if (!pat || !*pat) { free(pat); continue; }
            cJSON *x = cJSON_CreateObject();
            cJSON_AddStringToObject(x, "rule", name);
            cJSON_AddStringToObject(x, "pattern", pat);
            cJSON_AddItemToArray(exempt, x);
            free(pat);
        } else if (strcmp(dir, "agent") == 0) {
            /* agent <name> <exe|arg|team> <pattern> */
            char name[32];
            size_t nl = al < sizeof name - 1 ? al : sizeof name - 1;
            memcpy(name, arg, nl);
            name[nl] = '\0';
            const char *s = arg + al;
            while (*s == ' ' || *s == '\t') s++;
            const char *ke = s;
            while (*ke && *ke != ' ' && *ke != '\t') ke++;
            char how[8];
            size_t kl = (size_t)(ke - s) < sizeof how - 1 ? (size_t)(ke - s) : sizeof how - 1;
            memcpy(how, s, kl);
            how[kl] = '\0';
            char *pat = trimmed(ke);
            if (!pat || !*pat) { free(pat); continue; }
            cJSON *a = cJSON_CreateObject();
            cJSON_AddStringToObject(a, "name", name);
            cJSON_AddStringToObject(a, "kind", how);
            cJSON_AddStringToObject(a, "pattern", pat);
            cJSON_AddItemToArray(agents, a);
            free(pat);
        }
    }
    cJSON *sw = cJSON_AddObjectToObject(o, "switches");
    for (int i = 0; i < NSWITCHES; i++) cJSON_AddStringToObject(sw, SWITCHES[i].key, vals[i]);
    cJSON_AddItemToObject(o, "protect", protect);
    cJSON_AddItemToObject(o, "allow", allow);
    cJSON_AddItemToObject(o, "egress_allow", egress);
    cJSON_AddItemToObject(o, "channels", channels);
    cJSON_AddItemToObject(o, "terms", terms);
    cJSON_AddItemToObject(o, "rules", rules);
    cJSON_AddItemToObject(o, "agents", agents);
    cJSON_AddItemToObject(o, "exempt", exempt);
    lines_free(&L);
    print_json(o);
    return 0;
}

/* ---- loosening classification + pending confirmation (U0 hardening) ----
 * A change that LOOSENS protection (a wall to a weaker mode, a new allow or
 * exempt, removing a protect/rule/term/agent) is never applied straight away:
 * it is held as a pending request for the user to confirm in the Kai app. A
 * change that TIGHTENS (or leaves protection equal) applies immediately. This
 * holds regardless of caller, so a process that evades agent attribution (e.g.
 * one relaunched through launchd) still cannot quietly weaken Kai. */

/* Protection rank for a switch value: higher = more protective, -1 = this
 * switch does not express a protection level (so a change to it is neutral). */
static int switch_rank(const char *key, const char *val) {
    static const struct { const char *key; const char *order[6]; } R[] = {
        {"secrets",          {"off", "warn", "redact", "block", NULL}},
        {"on_prompt_secret", {"warn", "block", NULL}},
        {"on_file_secret",   {"warn", "ask", "block", NULL}},
        {"on_upload",        {"warn", "ask", "block", NULL}},
        {"on_fetch",         {"allow", "block", NULL}},
        {"injection",        {"off", "warn", NULL}},
        {"egress",           {"off", "log", "block", NULL}},
        {"storage",          {"off", "log", "block", NULL}},
        {"audit_context",    {"off", "on", NULL}},
    };
    for (size_t i = 0; i < sizeof R / sizeof R[0]; i++) {
        if (strcmp(R[i].key, key) != 0) continue;
        for (int j = 0; R[i].order[j]; j++)
            if (strcmp(R[i].order[j], val) == 0) return j;
        return -1;
    }
    return -1;
}

/* Would setting `key` to `newval` (from `oldval`) loosen protection? */
static int set_loosens(const char *key, const char *oldval, const char *newval) {
    if (strcmp(key, "max_scan_bytes") == 0) {
        long o = strtol(oldval ? oldval : "0", NULL, 10);
        long n = strtol(newval ? newval : "0", NULL, 10);
        return n < o;   /* scanning fewer bytes = less protection */
    }
    int ro = switch_rank(key, oldval ? oldval : "");
    int rn = switch_rank(key, newval);
    if (ro < 0 || rn < 0) return 0;  /* unranked (e.g. gateway_port): neutral */
    return rn < ro;
}

/* The audit records the process tree of whoever made the change: the Kai app
 * (its in-process writes) or, in the test seam, the CLI itself. */
static int g_caller_pid = 0;

/* Build "comm(pid) <- comm(ppid) <- ..." up the process tree and the calling
 * process's own code-signing Team ID, for the policy-change audit (#3). */
static void caller_context(char *chain, size_t chainlen, char *team, size_t teamlen) {
    chain[0] = '\0'; team[0] = '\0';
    int pid = g_caller_pid ? g_caller_pid : (int)getpid();
    sb_t b; sb_init(&b);
    for (int i = 0; i < 16 && pid > 0; i++) {
        kai_proc pr;
        if (kai_proc_read(pid, &pr) != 0) break;
        const char *base = strrchr(pr.exe, '/');
        base = base ? base + 1 : pr.exe;
        if (i) sb_adds(&b, " <- ");
        sb_addf(&b, "%s(%d)", base[0] ? base : "?", pid);
        if (i == 0 && pr.team[0]) kai_strlcpy(team, pr.team, teamlen);
        int parent = pr.ppid;
        kai_proc_free(&pr);
        if (parent <= 1 || parent == pid) { if (parent == 1) sb_adds(&b, " <- launchd(1)"); break; }
        pid = parent;
    }
    char *s = sb_take(&b);
    kai_strlcpy(chain, s, chainlen);
    free(s);
}

/* Queue a loosening change for the user to confirm in the Kai app. Writes
 * <home>/pending-policy/<id>.json with the proposed full policy text, a plain
 * summary and the caller context. Returns 0 (queued) or 1 (write error). */
static int policy_queue_pending(const char *summary, const char *proposed_txt,
                                const char *chain, const char *team) {
    char dir[1200];
    snprintf(dir, sizeof dir, "%s/pending-policy", kai_home());
    mkdir(kai_home(), 0700);
    mkdir(dir, 0700);
    static unsigned seq = 0;
    char id[64];
    snprintf(id, sizeof id, "%lld-%d-%u", (long long)time(NULL), (int)getpid(), seq++);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "id", id);
    cJSON_AddNumberToObject(o, "created_utc", (double)time(NULL));
    cJSON_AddStringToObject(o, "summary", summary);
    cJSON_AddStringToObject(o, "proposed_policy", proposed_txt);
    cJSON_AddStringToObject(o, "caller_chain", chain);
    cJSON_AddStringToObject(o, "caller_team", team[0] ? team : "(unsigned)");
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return 1;
    char path[1300];
    snprintf(path, sizeof path, "%s/%s.json", dir, id);
    int rc = policy_write_text(js, path);
    free(js);
    return rc;
}

/* Apply a validated change immediately (tightening/neutral) or hold it pending
 * the user's confirmation (loosening). Audits either way with the caller chain
 * and code-signing identity (#3). Returns a process exit code. */
static int policy_commit_or_queue(const lines_t *L, int loosens, const char *summary) {
    char *txt = lines_validate(L);
    if (!txt) return 2;
#ifdef KAI_TEST_DIRECT_POLICY
    loosens = 0;   /* test seam: apply directly so the cli suite can assert the
                      edit mechanics; the pending-hold is covered elsewhere. */
#endif
    char chain[512], team[32];
    caller_context(chain, sizeof chain, team, sizeof team);
    char detail[1200];
    snprintf(detail, sizeof detail, "%s | caller: %s | signed: %s",
             summary, chain, team[0] ? team : "(unsigned)");
    kai_audit_entry e = {0};
    e.source = "policy";
    e.event = loosens ? "loosen" : "tighten";
    e.decision = loosens ? "pending" : "applied";
    e.detail = detail;
    e.target = summary;
    if (loosens) {
        int rc = policy_queue_pending(summary, txt, chain, team);
        free(txt);
        kai_audit_write(&e);
        if (rc != 0) return 1;
        printf("Held for confirmation: \"%s\" would reduce protection.\n"
               "Open Kai and confirm it under Pending Changes to apply; it is NOT active yet.\n",
               summary);
        return 0;
    }
    int rc = policy_write_text(txt, NULL);
    free(txt);
    if (rc == 0) kai_audit_write(&e);
    return rc;
}

/* ---------- kai policy set ---------- */

static int policy_set(const char *key, const char *val) {
    int si = switch_index(key);
    if (si < 0) {
        fprintf(stderr, "kai policy set: unknown switch '%s'\n", key);
        switch_usage();
        return 1;
    }
    if (!switch_value_ok(si, val)) {
        fprintf(stderr, "kai policy set: '%s' is not a valid value for %s\n", val, key);
        switch_usage();
        return 1;
    }
    lines_t L;
    if (lines_load(&L) != 0) { fprintf(stderr, "kai policy: cannot read policy\n"); return 1; }
    char oldval[64]; kai_strlcpy(oldval, SWITCHES[si].def, sizeof oldval);  /* default if absent */
    int found = 0;
    for (int i = 0; i < L.n && !found; i++) {
        char dir[32];
        const char *arg;
        size_t al;
        if (!line_parts(L.v[i], dir, sizeof dir, &arg, &al) || strcmp(dir, key) != 0) continue;
        size_t on = al < sizeof oldval - 1 ? al : sizeof oldval - 1;
        memcpy(oldval, arg, on); oldval[on] = '\0';
        /* splice the new value over the old one, keeping layout and comment */
        sb_t b;
        sb_init(&b);
        size_t pre = (size_t)(arg - L.v[i]);
        sb_add(&b, L.v[i], pre);
        sb_adds(&b, val);
        sb_adds(&b, arg + al);
        free(L.v[i]);
        L.v[i] = sb_take(&b);
        found = 1;
    }
    if (!found) {
        sb_t b;
        sb_init(&b);
        sb_addf(&b, "%s %s", key, val);
        lines_push(&L, sb_take(&b));
    }
    int loosens = set_loosens(key, oldval, val);
    char summary[128];
    snprintf(summary, sizeof summary, "set %s %s->%s", key, oldval, val);
    int rc = policy_commit_or_queue(&L, loosens, summary);
    lines_free(&L);
    if (rc == 0 && !loosens) printf("%s = %s\n", key, val);
    return rc;
}

/* ---------- kai policy add / remove ---------- */

static char *join_args(int argc, char **argv) {
    sb_t b;
    sb_init(&b);
    for (int i = 0; i < argc; i++) {
        if (i) sb_adds(&b, " ");
        sb_adds(&b, argv[i]);
    }
    char *s = sb_take(&b);
    char *t = trimmed(s);
    free(s);
    return t;
}

static int has_newline(const char *s) { return strchr(s, '\n') || strchr(s, '\r'); }

/* Normalize an action argument. replace:X and replace:"X" both become
 * replace:"X". Returns NULL if invalid. */
static char *normalize_action(const char *a) {
    if (strcmp(a, "block") == 0 || strcmp(a, "redact") == 0 || strcmp(a, "warn") == 0)
        return strdup(a);
    if (strncmp(a, "replace:", 8) == 0) {
        const char *v = a + 8;
        size_t n = strlen(v);
        if (n >= 2 && v[0] == '"' && v[n - 1] == '"') { v++; n -= 2; }
        if (memchr(v, '"', n) || has_newline(v)) return NULL;
        sb_t b;
        sb_init(&b);
        sb_adds(&b, "replace:\"");
        sb_add(&b, v, n);
        sb_adds(&b, "\"");
        return sb_take(&b);
    }
    return NULL;
}

/* Index just after the last active line with this directive, or -1. */
static int last_of(const lines_t *L, const char *directive) {
    int at = -1;
    for (int i = 0; i < L->n; i++) {
        char dir[32];
        const char *arg;
        size_t al;
        if (line_parts(L->v[i], dir, sizeof dir, &arg, &al) && strcmp(dir, directive) == 0)
            at = i + 1;
    }
    return at;
}

/* Does line i hold directive with first argument equal to val? */
static int line_is(const lines_t *L, int i, const char *directive, const char *val) {
    char dir[32];
    const char *arg;
    size_t al;
    if (!line_parts(L->v[i], dir, sizeof dir, &arg, &al) || strcmp(dir, directive) != 0)
        return 0;
    return strlen(val) == al && strncmp(arg, val, al) == 0;
}

/* Does line i hold a term whose text equals text? */
static int term_is(const lines_t *L, int i, const char *text) {
    char dir[32];
    const char *arg;
    size_t al;
    if (!line_parts(L->v[i], dir, sizeof dir, &arg, &al) || strcmp(dir, "term") != 0)
        return 0;
    char *t = trimmed(action_end(arg));
    int eq = t && strcmp(t, text) == 0;
    free(t);
    return eq;
}

static void add_line(lines_t *L, const char *directive, char *line) {
    int at = last_of(L, directive);
    if (at < 0) lines_push(L, line);
    else lines_insert(L, at, line);
}

static int policy_add(int argc, char **argv) {
    if (argc < 2) goto usage;
    const char *kind = argv[0];
    lines_t L;
    if (lines_load(&L) != 0) { fprintf(stderr, "kai policy: cannot read policy\n"); return 1; }
    sb_t b;
    sb_init(&b);
    if (strcmp(kind, "protect") == 0 || strcmp(kind, "allow") == 0 ||
        strcmp(kind, "egress_allow") == 0) {
        const char *path = argv[1];
        if (argc != 2 || strpbrk(path, " \t#") || has_newline(path)) {
            fprintf(stderr, "kai policy add %s: one path, no spaces or '#'\n", kind);
            lines_free(&L);
            return 1;
        }
        if (strcmp(kind, "egress_allow") == 0 &&
            !kai_egress_entry_valid(strncmp(path, "*.", 2) == 0 ? path + 2 : path)) {
            fprintf(stderr, "kai policy add egress_allow: expected a host, IP address or range, "
                            "optionally with :port (example.com, db.example.com:5432, "
                            "10.0.0.0/8, 203.0.113.5:22, [2001:db8::1]:22)\n");
            lines_free(&L);
            return 1;
        }
        for (int i = 0; i < L.n; i++)
            if (line_is(&L, i, kind, path)) {
                printf("%s %s: already present\n", kind, path);
                lines_free(&L);
                return 0;
            }
        sb_addf(&b, "%s %s", kind, path);
        add_line(&L, kind, sb_take(&b));
    } else if (strcmp(kind, "term") == 0) {
        if (argc < 3) { lines_free(&L); goto usage; }
        char *act = normalize_action(argv[1]);
        char *text = join_args(argc - 2, argv + 2);
        if (!act || !text || !*text || has_newline(text)) {
            fprintf(stderr, "kai policy add term: action is block | redact | warn | "
                            "replace:\"text\", then the words to match\n");
            free(act); free(text); lines_free(&L);
            return 1;
        }
        for (int i = 0; i < L.n; i++)
            if (term_is(&L, i, text)) lines_remove(&L, i--); /* re-adding updates the action */
        sb_addf(&b, "term %s %s", act, text);
        add_line(&L, "term", sb_take(&b));
        free(act); free(text);
    } else if (strcmp(kind, "rule") == 0) {
        if (argc < 4) { lines_free(&L); goto usage; }
        const char *name = argv[1];
        char *act = normalize_action(argv[2]);
        char *pat = join_args(argc - 3, argv + 3);
        if (!act || !pat || !*pat || has_newline(pat) || strpbrk(name, " \t#")) {
            fprintf(stderr, "kai policy add rule: <name> <block|redact|warn|replace:\"x\"> <regex>\n");
            free(act); free(pat); lines_free(&L);
            return 1;
        }
        for (int i = 0; i < L.n; i++)
            if (line_is(&L, i, "rule", name)) lines_remove(&L, i--);
        sb_addf(&b, "rule %s %s %s", name, act, pat);
        add_line(&L, "rule", sb_take(&b));
        free(act); free(pat);
    } else if (strcmp(kind, "exempt") == 0) {
        /* exempt <rule> <glob>: let a command a rule wrongly blocks through,
         * for that rule only. Kai's own protection can't be exempted. */
        if (argc < 3) { lines_free(&L); goto usage; }
        const char *name = argv[1];
        char *pat = join_args(argc - 2, argv + 2);
        if (!pat || !*pat || has_newline(pat) || strchr(pat, '#') || strpbrk(name, " \t#") ||
            !*name) {
            fprintf(stderr, "kai policy add exempt: <rule> <command glob>, one line, no '#'\n"
                            "  (use ? for a '#' or a line break in the command)\n");
            free(pat); lines_free(&L);
            return 1;
        }
        if (kai_rule_is_builtin(name)) {
            fprintf(stderr, "kai policy add exempt: %s is Kai's own protection and can't be "
                            "exempted\n", name);
            free(pat); lines_free(&L);
            return 1;
        }
        sb_addf(&b, "exempt %s %s", name, pat);
        char *line = sb_take(&b);
        for (int i = 0; i < L.n; i++)
            if (strcmp(L.v[i], line) == 0) {
                printf("exempt %s: already present\n", name);
                free(line); free(pat); lines_free(&L);
                return 0;
            }
        add_line(&L, "exempt", line);
        free(pat);
    } else if (strcmp(kind, "agent") == 0) {
        /* agent <name> exe|arg|team <pattern>: teach Kai to recognize another
         * AI agent (for the network wall and the activity log). */
        if (argc < 4) { lines_free(&L); goto usage; }
        const char *name = argv[1], *how = argv[2];
        char *pat = join_args(argc - 3, argv + 3);
        int name_ok = *name && strlen(name) < 32;
        for (const char *c = name; *c; c++)
            if (!(isalnum((unsigned char)*c) || *c == '-' || *c == '_')) name_ok = 0;
        if (!name_ok || (strcmp(how, "exe") && strcmp(how, "arg") && strcmp(how, "team")) ||
            !pat || !*pat || has_newline(pat) || strchr(pat, '#')) {
            fprintf(stderr, "kai policy add agent: <name> exe|arg|team <pattern>\n"
                            "  exe   executable path, globs allowed   e.g. */bin/aider\n"
                            "  arg   any command-line argument        e.g. */opencode/*\n"
                            "  team  Apple code-signing Team ID       e.g. ABCDE12345\n");
            free(pat); lines_free(&L);
            return 1;
        }
        sb_addf(&b, "agent %s %s %s", name, how, pat);
        char *line = sb_take(&b);
        for (int i = 0; i < L.n; i++)
            if (strcmp(L.v[i], line) == 0) {
                printf("agent %s: already present\n", name);
                free(line); free(pat); lines_free(&L);
                return 0;
            }
        add_line(&L, "agent", line);
        free(pat);
    } else {
        lines_free(&L);
        goto usage;
    }
    /* allow / egress_allow / exempt grant access or lift a block => loosening. */
    int loosens = !strcmp(kind, "allow") || !strcmp(kind, "egress_allow") ||
                  !strcmp(kind, "exempt");
    char summary[160];
    snprintf(summary, sizeof summary, "add %s %s", kind, argc > 1 ? argv[1] : "");
    int rc = policy_commit_or_queue(&L, loosens, summary);
    lines_free(&L);
    if (rc == 0 && !loosens) printf("added %s\n", kind);
    return rc;
usage:
    fprintf(stderr, "usage: kai policy add protect|allow <path>\n"
                    "       kai policy add term <action> <text...>\n"
                    "       kai policy add rule <name> <action> <regex...>\n"
                    "       kai policy add agent <name> exe|arg|team <pattern>\n"
                    "       kai policy add exempt <rule> <command glob...>\n");
    return 1;
}

/* Does line i hold "exempt <rule> <pattern>" equal to val ("rule pattern")? */
static int exempt_is(const lines_t *L, int i, const char *val) {
    char dir[32];
    const char *arg;
    size_t al;
    if (!line_parts(L->v[i], dir, sizeof dir, &arg, &al) || strcmp(dir, "exempt") != 0) return 0;
    char *t = trimmed(arg);
    int eq = t && strcmp(t, val) == 0;
    free(t);
    return eq;
}

static int policy_remove(int argc, char **argv) {
    if (argc < 2) goto usage;
    const char *kind = argv[0];
    if (strcmp(kind, "protect") && strcmp(kind, "allow") && strcmp(kind, "term") &&
        strcmp(kind, "rule") && strcmp(kind, "egress_allow") && strcmp(kind, "agent") &&
        strcmp(kind, "exempt") && strcmp(kind, "channel"))
        goto usage;
    lines_t L;
    if (lines_load(&L) != 0) { fprintf(stderr, "kai policy: cannot read policy\n"); return 1; }
    char *val = join_args(argc - 1, argv + 1);
    int removed = 0;
    for (int i = 0; i < L.n; i++) {
        int hit = strcmp(kind, "term") == 0     ? term_is(&L, i, val)
                  : strcmp(kind, "exempt") == 0 ? exempt_is(&L, i, val)
                                                : line_is(&L, i, kind, val);
        if (hit) { lines_remove(&L, i--); removed++; }
    }
    if (!removed) {
        fprintf(stderr, "kai policy remove: no %s '%s' in the policy\n", kind, val);
        free(val); lines_free(&L);
        return 1;
    }
    /* Removing a protect/rule/term/agent drops protection => loosening.
     * Removing an allow/egress_allow/exempt restores a block => tightening. */
    int loosens = !strcmp(kind, "protect") || !strcmp(kind, "rule") ||
                  !strcmp(kind, "term") || !strcmp(kind, "agent");
    char summary[160];
    snprintf(summary, sizeof summary, "remove %s %s", kind, val);
    int rc = policy_commit_or_queue(&L, loosens, summary);
    lines_free(&L);
    if (rc == 0 && !loosens) printf("removed %s %s\n", kind, val);
    free(val);
    return rc;
usage:
    fprintf(stderr, "usage: kai policy remove protect|allow <path>\n"
                    "       kai policy remove term <text...>\n"
                    "       kai policy remove rule <name>\n"
                    "       kai policy remove exempt <rule> <command glob...>\n");
    return 1;
}

/* An agent-attributed process must never change Kai's policy (invariant: agent
 * config can request, never configure enforcement). Best-effort: refuse if our
 * own process tree traces to a known agent. A human terminal has no agent
 * ancestor. The ES storage wall additionally hard-denies ~/.kai writes when it
 * is active; this closes the CLI path even when the wall is off. */
static int policy_caller_is_agent(void) {
#ifdef KAI_TEST_DIRECT_POLICY
    /* Test seam, compile-time only: the CLI test suite runs inside the dev's
     * agent tree, which the refusal below would (correctly) block. This flag is
     * defined ONLY when building the throwaway cli-test binary, never for the
     * product or the signed app, so production always enforces the refusal. The
     * refusal and pending-hold are covered by run_storage_tests. */
    return 0;
#endif
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;                       /* can't determine: don't block the human */
    char name[64]; int apid;
    int hit = kai_process_agent(p, (int)getpid(), name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}

/* kai policy pending: list loosening changes awaiting the user's confirmation
 * in the Kai app. Read-only, so any caller (including an agent) may run it. */
static int policy_pending_list(void) {
    char dir[1200];
    snprintf(dir, sizeof dir, "%s/pending-policy", kai_home());
    DIR *d = opendir(dir);
    if (!d) { printf("No pending policy changes.\n"); return 0; }
    struct dirent *de;
    int n = 0;
    while ((de = readdir(d))) {
        size_t nl = strlen(de->d_name);
        if (nl < 6 || strcmp(de->d_name + nl - 5, ".json") != 0) continue;
        char path[1400];
        snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
        size_t len;
        char *txt = kai_read_file(path, 4000000, &len);
        if (!txt) continue;
        cJSON *o = cJSON_Parse(txt);
        free(txt);
        if (o) {
            const char *id = cJSON_GetStringValue(cJSON_GetObjectItem(o, "id"));
            const char *sum = cJSON_GetStringValue(cJSON_GetObjectItem(o, "summary"));
            const char *chain = cJSON_GetStringValue(cJSON_GetObjectItem(o, "caller_chain"));
            const char *team = cJSON_GetStringValue(cJSON_GetObjectItem(o, "caller_team"));
            printf("- %s\n    change:  %s\n    from:    %s\n    signed:  %s\n",
                   id ? id : de->d_name, sum ? sum : "?", chain ? chain : "?",
                   team ? team : "?");
            cJSON_Delete(o);
            n++;
        }
    }
    closedir(d);
    if (n == 0) printf("No pending policy changes.\n");
    else printf("\n%d pending change(s). Confirm or reject them in the Kai app; "
                "none are active yet.\n", n);
    return 0;
}

/* Testable core. `caller_is_agent` is supplied by the caller so tests can
 * exercise the loosen/pending/tighten logic independent of the real process
 * tree (which, under an agent, would always refuse). Production passes the
 * result of policy_caller_is_agent(). */
int kai_policy_dispatch(int argc, char **argv, int caller_is_agent) {
    const char *sub = argc > 0 ? argv[0] : "show";
    if ((!strcmp(sub, "set") || !strcmp(sub, "add") || !strcmp(sub, "remove"))
        && caller_is_agent) {
        fprintf(stderr, "kai policy %s: refused -- an agent-attributed process cannot "
                        "change Kai's policy.\n", sub);
        return 3;
    }
    if (strcmp(sub, "path") == 0) { printf("%s\n", kai_policy_file()); return 0; }
    if (strcmp(sub, "pending") == 0) return policy_pending_list();
    if (strcmp(sub, "show") == 0)
        return policy_show(argc > 1 && strcmp(argv[1], "--json") == 0);
    if (strcmp(sub, "set") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: kai policy set <switch> <value>\n");
            switch_usage();
            return 1;
        }
        return policy_set(argv[1], argv[2]);
    }
    if (strcmp(sub, "add") == 0) return policy_add(argc - 1, argv + 1);
    if (strcmp(sub, "remove") == 0) return policy_remove(argc - 1, argv + 1);
    fprintf(stderr, "usage: kai policy [path | show [--json] | pending | set | add | remove]\n");
    return 1;
}

/* v1: the Kai app is the ONLY writer of policy and permissions, in-process.
 * The CLI shows them (policy show, status, sessions, agents, why, denials) but
 * a change is made in Kai: say so and open the matching Settings page. (CLI
 * writes may return later, with signature checks in both directions.) The
 * window opens only for a person at a terminal, never for a script or agent. */
static const struct { const char *page, *title; } SETTINGS_PAGES[] = {
    {"files", "Files"}, {"internet", "Internet"}, {"advanced", "Advanced"},
    {"agentControl", "Agent Control"},
};

const char *kai_settings_page_for(int argc, char **argv) {
    const char *sub = argc > 0 ? argv[0] : "";
    const char *what = argc > 1 ? argv[1] : "";
    if (!strcmp(sub, "create") || !strcmp(sub, "revoke")) return "agentControl";   /* kai grant */
    if (!strcmp(sub, "set"))
        return !strcmp(what, "storage") ? "files" : !strcmp(what, "egress") ? "internet" : "advanced";
    if (!strcmp(sub, "add") || !strcmp(sub, "remove"))
        return (!strcmp(what, "protect") || !strcmp(what, "allow")) ? "files"
             : (!strcmp(what, "egress_allow") || !strcmp(what, "channel")) ? "internet" : "advanced";
    return "advanced";
}

int kai_cli_change_in_kai(int argc, char **argv) {
    const char *page = kai_settings_page_for(argc, argv), *title = page;
    for (size_t i = 0; i < sizeof SETTINGS_PAGES / sizeof SETTINGS_PAGES[0]; i++)
        if (!strcmp(SETTINGS_PAGES[i].page, page)) title = SETTINGS_PAGES[i].title;
    fprintf(stderr, "Change this in Kai: Settings \xE2\x86\x92 %s.\n"
                    "(In this version the kai command shows policy and permissions but doesn't change them.)\n",
            title);
    if (isatty(STDIN_FILENO) && isatty(STDERR_FILENO)) {
        char url[128]; snprintf(url, sizeof url, "kai://settings/%s", page);
        pid_t pid;
        char *av[] = {"/usr/bin/open", url, NULL};
        extern char **environ;
        if (posix_spawn(&pid, "/usr/bin/open", NULL, NULL, av, environ) == 0) waitpid(pid, NULL, 0);
    }
    return 4;
}

int kai_cmd_policy(int argc, char **argv) {
    const char *sub = argc > 0 ? argv[0] : "show";
    int is_write = !strcmp(sub, "set") || !strcmp(sub, "add") || !strcmp(sub, "remove");
#ifndef KAI_TEST_DIRECT_POLICY
    if (is_write) return kai_cli_change_in_kai(argc, argv);
#endif
    int is_agent = is_write && policy_caller_is_agent();
    return kai_policy_dispatch(argc, argv, is_agent);
}
