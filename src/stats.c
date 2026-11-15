// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
/*
 * C4 / Phase 5 (0.3.0-preview.1): the decision record, read back.
 *
 *   kai why <decision-id|record-hash> [--json]
 *       One stop in plain words: component, rule, target, session, how the
 *       session was attributed, the recovery, and "Retry would now be": the
 *       decision re-run against today's policy where Kai can re-run it.
 *   kai not-right <decision-id>
 *       The owner marks a stop as a false positive (counted by kai stats).
 *   kai stats --export [--days N]
 *       Local aggregate counts for the developer study. No prompts, paths,
 *       commands or code: only counts per agent and day. Printed to stdout;
 *       nothing is ever sent anywhere.
 *
 * Every field comes from records Kai already wrote (secret-redacted).
 */
#include "cJSON.h"
#include "internal.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *js(const cJSON *o, const char *k) {
    const char *v = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(o, k));
    return v ? v : "";
}

typedef struct { cJSON **v; int n, cap; } recs_t;

static void push(recs_t *r, cJSON *o) {
    if (r->n == r->cap) {
        int cap = r->cap ? r->cap * 2 : 256;
        cJSON **nv = realloc(r->v, (size_t)cap * sizeof *nv);
        if (!nv) { cJSON_Delete(o); return; }
        r->v = nv; r->cap = cap;
    }
    r->v[r->n++] = o;
}

static void load_file(recs_t *r, const char *path) {
    size_t n = 0;
    char *t = kai_read_file(path, 32u << 20, &n);
    if (!t) return;
    char *save = NULL;
    for (char *line = strtok_r(t, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        cJSON *o = cJSON_Parse(line);
        if (o) push(r, o);
    }
    free(t);
}

/* The audit log, oldest first (the rotated file, then the current one). */
static recs_t load_audit(void) {
    recs_t r = {0};
    char old[1200];
    snprintf(old, sizeof old, "%s.1", kai_audit_path());
    load_file(&r, old);
    load_file(&r, kai_audit_path());
    return r;
}

static void free_recs(recs_t *r) {
    for (int i = 0; i < r->n; i++) cJSON_Delete(r->v[i]);
    free(r->v);
}

static const char *agent_of(const cJSON *o) {
    const char *s = js(o, "source");
    if (!strcmp(s, "network") || !strcmp(s, "gateway") || !strcmp(s, "storage")) s = js(o, "event");
    if (!strcmp(s, "claude")) return "Claude Code";
    if (!strcmp(s, "cursor")) return "Cursor";
    if (!strcmp(s, "codex")) return "Codex";
    return *s ? s : "Unattributed";
}

static const char *component_of(const cJSON *o) {
    const char *s = js(o, "source");
    if (!strcmp(s, "claude") || !strcmp(s, "cursor") || !strcmp(s, "codex")) return "agent hook";
    if (!strcmp(s, "network") || !strcmp(s, "gateway")) return "network wall";
    if (!strcmp(s, "storage")) return "storage wall";
    return s;
}

/* How Kai knew which agent and session this was. A hook event is sent by the
 * agent itself, so the agent is certain and the session is the agent's id.
 * A wall record is attributed by process lineage and signing identity; with
 * neither, it is Unattributed (never guessed). */
static void attribution_of(const cJSON *o, char *out, size_t n) {
    const char *comp = component_of(o), *sess = js(o, "session"), *id = js(o, "identity");
    if (!strcmp(comp, "agent hook")) {
        snprintf(out, n, "hook: %s%s%.8s", agent_of(o), *sess ? " session " : "", sess);
    } else if (*id) {
        snprintf(out, n, "process lineage, signed as %s", id);
    } else if (strcmp(agent_of(o), "Unattributed") != 0) {
        snprintf(out, n, "process lineage (identity unverified)");
    } else {
        snprintf(out, n, "Unattributed");
    }
}

/* The recovery the stop already named, or a plain default. */
static void recovery_of(const cJSON *o, char *out, size_t n) {
    const char *d = js(o, "detail"), *rule = js(o, "rule"), *dec = js(o, "decision");
    static const char *const starts[] = {"If this was intended", "If you need", "To allow", "(to allow", NULL};
    for (int i = 0; starts[i]; i++) {
        const char *s = strstr(d, starts[i]);
        if (!s) continue;
        size_t l = strlen(s);
        const char *e = strstr(s, " Don't retry");
        if (!e) e = strstr(s, " (Kai decision");
        if (e) l = (size_t)(e - s);
        snprintf(out, n, "%.*s", (int)l, s);
        return;
    }
    if (!strcmp(rule, "kai_self_protect") || kai_rule_is_builtin(rule))
        snprintf(out, n, "Agents may not change Kai's or the agents' hook settings. If you meant to, change it "
                         "yourself in your own terminal or in Kai's Settings.");
    else if (!strcmp(rule, "credential_print"))
        snprintf(out, n, "Run the command in your own terminal if you need the value; gh and git keep working.");
    else if (!strcmp(dec, "ask"))
        snprintf(out, n, "Approve it in the agent's own prompt if it was intended.");
    else if (!strcmp(component_of(o), "network wall"))
        snprintf(out, n, "Allow the site for this task in Kai, or keep it blocked.");
    else
        snprintf(out, n, "If it was intended, allow it in Kai; otherwise nothing is needed.");
}

static int is_file_tool(const char *t) {
    return !strcmp(t, "Read") || !strcmp(t, "Write") || !strcmp(t, "Edit") || !strcmp(t, "MultiEdit") ||
           !strcmp(t, "NotebookEdit") || !strcmp(t, "NotebookRead") || !strcmp(t, "ReadFile");
}

static int is_shell_tool(const char *t) {
    return !strcmp(t, "Bash") || !strcmp(t, "Shell") || !strcmp(t, "shell") || !strcmp(t, "exec_command");
}

static const char *agent_key(const cJSON *o) {
    const char *s = js(o, "source");
    return (!strcmp(s, "claude") || !strcmp(s, "cursor") || !strcmp(s, "codex")) ? s : NULL;
}

/* "Retry would now be": re-run what Kai can re-run from the record. */
static void retry_of(const cJSON *o, char *out, size_t n) {
    const char *tool = js(o, "tool"), *target = js(o, "target"), *cwd = js(o, "cwd");
    if (strcmp(component_of(o), "agent hook") != 0) {
        snprintf(out, n, "not re-checkable here: the %s decides when the connection or file is opened",
                 component_of(o));
        return;
    }
    if (!*target) { snprintf(out, n, "not re-checkable: the record has no target"); return; }
    if (strstr(target, "REDACTED") || strstr(target, "[redacted")) {
        snprintf(out, n, "not re-checkable: the record's target had a secret removed");
        return;
    }
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { snprintf(out, n, "not re-checkable: Kai can't read its rules (%s)", err); return; }
    char rule[256] = "";
    int stop = 0;
    if (is_file_tool(tool)) {
        int write = strcmp(tool, "Read") && strcmp(tool, "NotebookRead") && strcmp(tool, "ReadFile");
        stop = kai_path_protected_as(p, agent_key(o), target, *cwd ? cwd : NULL, rule, sizeof rule) &&
               (write || !kai_control_read_allowed(rule));
    } else if (is_shell_tool(tool)) {
        stop = kai_hook_recheck_command(p, agent_key(o), target, *cwd ? cwd : NULL, rule, sizeof rule);
    } else if (!strncmp(tool, "mcp__", 5)) {
        kai_policy_free(p);
        snprintf(out, n, "not re-checkable here: MCP decisions depend on the agent's permission mode; "
                         "ask the agent to try once more");
        return;
    } else {
        kai_policy_free(p);
        snprintf(out, n, "not re-checkable here: Kai re-runs file and shell decisions only");
        return;
    }
    kai_policy_free(p);
    if (stop) snprintf(out, n, "stopped (rule %s)", rule);
    else snprintf(out, n, "allowed");
}

static const cJSON *find_record(const recs_t *r, const char *id) {
    size_t l = strlen(id);
    for (int i = r->n - 1; i >= 0; i--)
        if (!strcmp(js(r->v[i], "decision_id"), id)) return r->v[i];
    for (int i = r->n - 1; i >= 0 && l >= 6; i--)
        if (!strncmp(js(r->v[i], "h"), id, l)) return r->v[i];
    return NULL;
}

int kai_cmd_why_decision(int argc, char **argv) {
    const char *id = NULL;
    int json = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!id) id = argv[i];
    }
    if (!id) {
        fprintf(stderr, "usage: kai why <decision-id> [--json]   (ids like k-1a2b3c4d, from Kai's stop messages "
                        "or `kai denials`)\n");
        return 2;
    }
    recs_t r = load_audit();
    const cJSON *hit = find_record(&r, id);
    if (!hit) {
        fprintf(stderr, "kai why: no record for '%s'\n", id);
        free_recs(&r);
        return 1;
    }
    char att[256], rec[600], retry[400];
    attribution_of(hit, att, sizeof att);
    recovery_of(hit, rec, sizeof rec);
    retry_of(hit, retry, sizeof retry);
    const char *did = js(hit, "decision_id");
    if (json) {
        cJSON *o = cJSON_CreateObject();
        cJSON_AddStringToObject(o, "id", *did ? did : id);
        cJSON_AddStringToObject(o, "ts", js(hit, "ts"));
        cJSON_AddStringToObject(o, "agent", agent_of(hit));
        cJSON_AddStringToObject(o, "component", component_of(hit));
        cJSON_AddStringToObject(o, "decision", js(hit, "decision"));
        cJSON_AddStringToObject(o, "rule", js(hit, "rule"));
        cJSON_AddStringToObject(o, "target", js(hit, "target"));
        cJSON_AddStringToObject(o, "session", js(hit, "session"));
        cJSON_AddStringToObject(o, "attribution", att);
        cJSON_AddStringToObject(o, "recovery", rec);
        cJSON_AddStringToObject(o, "reason", js(hit, "detail"));
        cJSON_AddStringToObject(o, "retry", retry);
        char *s = cJSON_PrintUnformatted(o);
        printf("%s\n", s);
        free(s);
        cJSON_Delete(o);
    } else {
        printf("%s  %s  %s\n", *did ? did : id, js(hit, "ts"), agent_of(hit));
        printf("  component:   %s\n", component_of(hit));
        printf("  decision:    %s\n", js(hit, "decision"));
        printf("  rule:        %s\n", js(hit, "rule"));
        if (*js(hit, "target")) printf("  target:      %s\n", js(hit, "target"));
        if (*js(hit, "session")) printf("  session:     %s\n", js(hit, "session"));
        printf("  attribution: %s\n", att);
        if (*js(hit, "detail")) printf("  reason:      %s\n", js(hit, "detail"));
        printf("  recovery:    %s\n", rec);
        printf("  Retry would now be: %s\n", retry);
    }
    free_recs(&r);
    return 0;
}

/* ---- false-positive marks ---- */

static void flags_path(char *out, size_t n) { snprintf(out, n, "%s/flags.log", kai_home()); }

int kai_cmd_not_right(int argc, char **argv) {
    if (argc < 1 || strncmp(argv[0], "k-", 2) != 0) {
        fprintf(stderr, "usage: kai not-right <decision-id>   (marks a stop as wrong, for kai stats)\n");
        return 2;
    }
    recs_t r = load_audit();
    const cJSON *hit = find_record(&r, argv[0]);
    if (!hit) { fprintf(stderr, "kai not-right: no record for '%s'\n", argv[0]); free_recs(&r); return 1; }
    char path[1200], ts[32];
    flags_path(path, sizeof path);
    time_t now = time(NULL);
    struct tm tmv;
    gmtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", &tmv);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "ts", ts);
    cJSON_AddStringToObject(o, "decision_id", argv[0]);
    cJSON_AddStringToObject(o, "agent", js(hit, "source"));
    cJSON_AddStringToObject(o, "rule", js(hit, "rule"));
    char *line = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    FILE *f = fopen(path, "a");
    int ok = f && fprintf(f, "%s\n", line) > 0;
    if (f) fclose(f);
    free(line);
    free_recs(&r);
    if (!ok) { fprintf(stderr, "kai not-right: couldn't write %s\n", path); return 1; }
    printf("Marked %s as not right. Thanks: it's counted in `kai stats --export`.\n", argv[0]);
    return 0;
}

/* ---- kai stats --export ---- */

typedef struct {
    char day[11];
    char agent[16];
    int stops, asks, warns, redactions, unchecked, flagged;
} cell_t;

typedef struct { cell_t *v; int n, cap; } cells_t;

static cell_t *cell(cells_t *c, const char *day, const char *agent) {
    for (int i = 0; i < c->n; i++)
        if (!strcmp(c->v[i].day, day) && !strcmp(c->v[i].agent, agent)) return &c->v[i];
    if (c->n == c->cap) {
        int cap = c->cap ? c->cap * 2 : 64;
        cell_t *nv = realloc(c->v, (size_t)cap * sizeof *nv);
        if (!nv) return NULL;
        c->v = nv; c->cap = cap;
    }
    cell_t *x = &c->v[c->n++];
    memset(x, 0, sizeof *x);
    kai_strlcpy(x->day, day, sizeof x->day);
    kai_strlcpy(x->agent, agent, sizeof x->agent);
    return x;
}

/* Only the three agents (and "kai" for pause/uninstall) are ever named. */
static const char *study_agent(const char *src) {
    if (!strcmp(src, "claude") || !strcmp(src, "cursor") || !strcmp(src, "codex")) return src;
    return NULL;
}

static int since_ok(const char *ts, const char *since) { return strncmp(ts, since, 10) >= 0; }

int kai_cmd_stats(int argc, char **argv) {
    int days = 30, exp = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--export")) exp = 1;
        else if (!strcmp(argv[i], "--days") && i + 1 < argc) days = atoi(argv[++i]);
    }
    if (!exp) {
        fprintf(stderr, "usage: kai stats --export [--days N]\n"
                        "  Local counts for the developer study (stops, asks, unchecked calls, pauses,\n"
                        "  false-positive marks, coverage), per agent and day. No prompts, paths or code.\n"
                        "  Printed to stdout; Kai sends nothing.\n");
        return 2;
    }
    if (days < 1) days = 1;
    char since[16];
    time_t t0 = time(NULL) - (time_t)days * 86400;
    struct tm tmv;
    gmtime_r(&t0, &tmv);
    strftime(since, sizeof since, "%Y-%m-%d", &tmv);

    cells_t c = {0};
    int pauses = 0, pause_minutes = 0, resumes = 0, uninstalls = 0, repairs = 0;
    recs_t r = load_audit();
    for (int i = 0; i < r.n; i++) {
        const cJSON *o = r.v[i];
        const char *ts = js(o, "ts"), *src = js(o, "source"), *dec = js(o, "decision"), *ev = js(o, "event");
        if (strlen(ts) < 10 || !since_ok(ts, since)) continue;
        char day[11];
        snprintf(day, sizeof day, "%.10s", ts);
        if (!strcmp(src, "pause") || (!strcmp(src, "session") && !strcmp(ev, "pause"))) {
            if (!strcmp(dec, "paused")) {
                pauses++;
                const char *d = js(o, "detail"), *m = strstr(d, "paused ");
                if (m) pause_minutes += atoi(m + 7);
            } else if (!strcmp(dec, "resumed")) {
                resumes++;
            }
            continue;
        }
        if (!strcmp(src, "kai") && !strcmp(ev, "uninstall")) { uninstalls++; continue; }
        if (!strcmp(src, "kai") && !strcmp(ev, "doctor-fix")) { repairs++; continue; }
        const char *a = study_agent(src);
        if (!a) continue;
        cell_t *x = cell(&c, day, a);
        if (!x) continue;
        if (!strcmp(dec, "block")) x->stops++;
        else if (!strcmp(dec, "ask")) x->asks++;
        else if (!strcmp(dec, "warn")) x->warns++;
        else if (!strcmp(dec, "redact") || !strcmp(dec, "replace")) x->redactions++;
    }
    free_recs(&r);

    recs_t u = {0};
    char path[1200];
    snprintf(path, sizeof path, "%s/unchecked.log", kai_home());
    load_file(&u, path);
    for (int i = 0; i < u.n; i++) {
        const char *ts = js(u.v[i], "ts"), *a = study_agent(js(u.v[i], "agent"));
        if (!a || strlen(ts) < 10 || !since_ok(ts, since)) continue;
        char day[11];
        snprintf(day, sizeof day, "%.10s", ts);
        cell_t *x = cell(&c, day, a);
        if (x) x->unchecked++;
    }
    free_recs(&u);

    recs_t fl = {0};
    flags_path(path, sizeof path);
    load_file(&fl, path);
    for (int i = 0; i < fl.n; i++) {
        const char *ts = js(fl.v[i], "ts"), *a = study_agent(js(fl.v[i], "agent"));
        if (!a || strlen(ts) < 10 || !since_ok(ts, since)) continue;
        char day[11];
        snprintf(day, sizeof day, "%.10s", ts);
        cell_t *x = cell(&c, day, a);
        if (x) x->flagged++;
    }
    free_recs(&fl);

    cJSON *out = cJSON_CreateObject();
    cJSON_AddStringToObject(out, "kai_version", KAI_VERSION);
    cJSON_AddStringToObject(out, "since", since);
    cJSON_AddNumberToObject(out, "days", days);
    cJSON_AddStringToObject(out, "note", "Counts only. No prompts, paths, commands, code or hostnames.");
    cJSON *rows = cJSON_AddArrayToObject(out, "per_day_agent");
    for (int i = 0; i < c.n; i++) {
        cJSON *x = cJSON_CreateObject();
        cJSON_AddStringToObject(x, "day", c.v[i].day);
        cJSON_AddStringToObject(x, "agent", c.v[i].agent);
        cJSON_AddNumberToObject(x, "stops", c.v[i].stops);
        cJSON_AddNumberToObject(x, "asks", c.v[i].asks);
        cJSON_AddNumberToObject(x, "warnings", c.v[i].warns);
        cJSON_AddNumberToObject(x, "redactions", c.v[i].redactions);
        cJSON_AddNumberToObject(x, "unchecked_calls", c.v[i].unchecked);
        cJSON_AddNumberToObject(x, "marked_not_right", c.v[i].flagged);
        cJSON_AddItemToArray(rows, x);
    }
    cJSON *pz = cJSON_AddObjectToObject(out, "lowering_protection");
    cJSON_AddNumberToObject(pz, "pauses", pauses);
    cJSON_AddNumberToObject(pz, "pause_minutes_requested", pause_minutes);
    cJSON_AddNumberToObject(pz, "early_resumes", resumes);
    cJSON_AddNumberToObject(pz, "uninstalls", uninstalls);
    cJSON_AddNumberToObject(pz, "repairs", repairs);
    /* Coverage today: which agents have Kai's hooks (no paths). Past days
     * aren't recorded; unchecked_calls per day is the measured gap. */
    cJSON *cov = cJSON_AddObjectToObject(out, "coverage_today");
    static const char *const ags[] = {"claude", "cursor", "codex"};
    for (size_t i = 0; i < 3; i++)
        {
        int on = kai_agent_checks_on(ags[i]);
        cJSON_AddStringToObject(cov, ags[i], on > 0 ? "checking" : on == 0 ? "not checking" : "not supported");
    }
    char *s = cJSON_Print(out);
    printf("%s\n", s);
    free(s);
    cJSON_Delete(out);
    free(c.v);
    return 0;
}
