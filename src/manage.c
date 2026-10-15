/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Machine-readable status and safe policy editing. Used by the menu-bar app
 * and handy from scripts:
 *
 *   kai status --json
 *   kai policy path
 *   kai policy show [--json]
 *   kai policy set <switch> <value>
 *   kai policy add protect|allow <path>
 *   kai policy add term <action> <text...>
 *   kai policy add rule <name> <action> <regex...>
 *   kai policy remove protect|allow <path>
 *   kai policy remove term <text...>
 *   kai policy remove rule <name>
 *
 * Edits keep the file's comments and layout, are validated by parsing the
 * result before anything is written, and replace the file atomically.
 */
#include "cJSON.h"
#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---------- small helpers ---------- */

static int agent_installed(const char *rel, const char *needle, int *detected) {
    char *path = kai_expand_home(rel);
    size_t n;
    char *s = kai_read_file(path, 4 * 1024 * 1024, &n);
    int on = s && strstr(s, needle);
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

    const struct { const char *name, *rel, *needle; } agents[] = {
        {"claude", "~/.claude/settings.json", "hook claude"},
        {"cursor", "~/.cursor/hooks.json", "hook cursor"},
    };
    for (size_t i = 0; i < sizeof agents / sizeof agents[0]; i++) {
        int detected = 0;
        int on = agent_installed(agents[i].rel, agents[i].needle, &detected);
        cJSON *a = cJSON_AddObjectToObject(o, agents[i].name);
        cJSON_AddBoolToObject(a, "installed", on);
        cJSON_AddBoolToObject(a, "detected", detected);
        char *cfg = kai_expand_home(agents[i].rel);
        cJSON_AddStringToObject(a, "config", cfg);
        free(cfg);
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

    print_json(o);
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

/* Validate, then write via temp file + rename so a reader never sees half a policy. */
static int lines_save(const lines_t *L) {
    char *txt = lines_join(L);
    char err[256];
    kai_policy *p = kai_policy_from_string(txt, err, sizeof err);
    if (!p) {
        fprintf(stderr, "kai policy: change rejected, it would break the policy: %s\n", err);
        free(txt);
        return 2;
    }
    kai_policy_free(p);

    mkdir(kai_home(), 0700);
    const char *path = kai_policy_file();
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) { fprintf(stderr, "kai policy: cannot write %s\n", tmp); free(txt); return 1; }
    chmod(tmp, 0600);
    size_t len = strlen(txt);
    int ok = fwrite(txt, 1, len, f) == len;
    ok = (fflush(f) == 0) && ok;
    ok = (fsync(fileno(f)) == 0) && ok;
    ok = (fclose(f) == 0) && ok;
    free(txt);
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        fprintf(stderr, "kai policy: cannot write %s\n", path);
        return 1;
    }
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
    {"on_file_secret", "block", {"block", "warn", NULL}},
    {"on_upload", "block", {"block", "ask", NULL}},
    {"injection", "warn", {"warn", "off", NULL}},
    {"max_scan_bytes", "2000000", {NULL}},
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
        } else if (strcmp(dir, "protect") == 0 || strcmp(dir, "allow") == 0) {
            char *v = malloc(al + 1);
            if (!v) continue;
            memcpy(v, arg, al);
            v[al] = '\0';
            cJSON_AddItemToArray(dir[0] == 'p' ? protect : allow, cJSON_CreateString(v));
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
        }
    }
    cJSON *sw = cJSON_AddObjectToObject(o, "switches");
    for (int i = 0; i < NSWITCHES; i++) cJSON_AddStringToObject(sw, SWITCHES[i].key, vals[i]);
    cJSON_AddItemToObject(o, "protect", protect);
    cJSON_AddItemToObject(o, "allow", allow);
    cJSON_AddItemToObject(o, "terms", terms);
    cJSON_AddItemToObject(o, "rules", rules);
    lines_free(&L);
    print_json(o);
    return 0;
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
    int found = 0;
    for (int i = 0; i < L.n && !found; i++) {
        char dir[32];
        const char *arg;
        size_t al;
        if (!line_parts(L.v[i], dir, sizeof dir, &arg, &al) || strcmp(dir, key) != 0) continue;
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
    int rc = lines_save(&L);
    lines_free(&L);
    if (rc == 0) printf("%s = %s\n", key, val);
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
    if (strcmp(kind, "protect") == 0 || strcmp(kind, "allow") == 0) {
        const char *path = argv[1];
        if (argc != 2 || strpbrk(path, " \t#") || has_newline(path)) {
            fprintf(stderr, "kai policy add %s: one path, no spaces or '#'\n", kind);
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
    } else {
        lines_free(&L);
        goto usage;
    }
    int rc = lines_save(&L);
    lines_free(&L);
    if (rc == 0) printf("added %s\n", kind);
    return rc;
usage:
    fprintf(stderr, "usage: kai policy add protect|allow <path>\n"
                    "       kai policy add term <action> <text...>\n"
                    "       kai policy add rule <name> <action> <regex...>\n");
    return 1;
}

static int policy_remove(int argc, char **argv) {
    if (argc < 2) goto usage;
    const char *kind = argv[0];
    if (strcmp(kind, "protect") && strcmp(kind, "allow") && strcmp(kind, "term") &&
        strcmp(kind, "rule"))
        goto usage;
    lines_t L;
    if (lines_load(&L) != 0) { fprintf(stderr, "kai policy: cannot read policy\n"); return 1; }
    char *val = join_args(argc - 1, argv + 1);
    int removed = 0;
    for (int i = 0; i < L.n; i++) {
        int hit = strcmp(kind, "term") == 0 ? term_is(&L, i, val) : line_is(&L, i, kind, val);
        if (hit) { lines_remove(&L, i--); removed++; }
    }
    if (!removed) {
        fprintf(stderr, "kai policy remove: no %s '%s' in the policy\n", kind, val);
        free(val); lines_free(&L);
        return 1;
    }
    int rc = lines_save(&L);
    lines_free(&L);
    if (rc == 0) printf("removed %s %s\n", kind, val);
    free(val);
    return rc;
usage:
    fprintf(stderr, "usage: kai policy remove protect|allow <path>\n"
                    "       kai policy remove term <text...>\n"
                    "       kai policy remove rule <name>\n");
    return 1;
}

int kai_cmd_policy(int argc, char **argv) {
    const char *sub = argc > 0 ? argv[0] : "show";
    if (strcmp(sub, "path") == 0) { printf("%s\n", kai_policy_file()); return 0; }
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
    fprintf(stderr, "usage: kai policy [path | show [--json] | set | add | remove]\n");
    return 1;
}
