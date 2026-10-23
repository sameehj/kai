/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Reading the audit log as a person, and reporting Kai's mistakes.
 *
 *   kai log show [-n N]          recent decisions in words, with what was
 *                                blocked and what the agent did next
 *   kai report <id> [--json]     a false-positive report for one record:
 *                                written to <kai home>/reports/, plus a
 *                                GitHub issue link to open and review.
 *                                Nothing is sent anywhere.
 *
 * <id> is the start of a record's hash ("h"), as `kai log show` prints it.
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE /* timegm, strptime on glibc */
#endif
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif
#include "cJSON.h"
#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define REPORT_REPO "https://github.com/sameehj/kai"

static const char *jstr(const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return (cJSON_IsString(v) && v->valuestring) ? v->valuestring : "";
}

/* "2026-10-16T20:06:00Z" -> local "2026-10-16 23:06" */
static void local_time(const char *ts, char *out, size_t outlen) {
    struct tm tmv;
    memset(&tmv, 0, sizeof tmv);
    if (!strptime(ts, "%Y-%m-%dT%H:%M:%SZ", &tmv)) { kai_strlcpy(out, ts, outlen); return; }
    time_t t = timegm(&tmv);
    struct tm lt;
    localtime_r(&t, &lt);
    strftime(out, outlen, "%Y-%m-%d %H:%M", &lt);
}

/* Both log files, oldest first (audit.log.1 is what rotation kept). */
static char *read_logs(void) {
    char old[1200];
    snprintf(old, sizeof old, "%s.1", kai_audit_path());
    size_t n;
    sb_t b;
    sb_init(&b);
    char *a = kai_read_file(old, 16 * 1024 * 1024, &n);
    if (a) { sb_adds(&b, a); free(a); }
    a = kai_read_file(kai_audit_path(), 16 * 1024 * 1024, &n);
    if (a) { sb_adds(&b, a); free(a); }
    return sb_take(&b);
}

/* Parsed records, oldest first. */
typedef struct {
    cJSON **v;
    int n;
} records_t;

static records_t load_records(void) {
    records_t r = {NULL, 0};
    char *txt = read_logs();
    int cap = 0;
    for (char *line = strtok(txt, "\n"); line; line = strtok(NULL, "\n")) {
        cJSON *o = cJSON_Parse(line);
        if (!o) continue;
        if (r.n == cap) {
            cap = cap ? cap * 2 : 256;
            cJSON **nv = realloc(r.v, (size_t)cap * sizeof *nv);
            if (!nv) { cJSON_Delete(o); break; }
            r.v = nv;
        }
        r.v[r.n++] = o;
    }
    free(txt);
    return r;
}

static void free_records(records_t *r) {
    for (int i = 0; i < r->n; i++) cJSON_Delete(r->v[i]);
    free(r->v);
}

static const char *agent_name(const cJSON *o) {
    const char *s = jstr(o, "source");
    if (!strcmp(s, "network") || !strcmp(s, "gateway")) s = jstr(o, "event");
    if (!strcmp(s, "claude")) return "Claude Code";
    if (!strcmp(s, "cursor")) return "Cursor";
    if (!strcmp(s, "codex")) return "Codex";
    return s;
}

/* The follow-up note written after record i, if any: same session and rule. */
static const cJSON *follow_up_of(const records_t *r, int i) {
    const char *sess = jstr(r->v[i], "session");
    if (!*sess) return NULL;
    for (int k = i + 1; k < r->n; k++) {
        const cJSON *o = r->v[k];
        if (strcmp(jstr(o, "session"), sess) != 0) continue;
        if (!strcmp(jstr(o, "decision"), "note")) return strcmp(jstr(o, "rule"), jstr(r->v[i], "rule")) == 0 ? o : NULL;
        if (!strcmp(jstr(o, "decision"), "block")) return NULL; /* the next block has its own */
    }
    return NULL;
}

static int log_show(int argc, char **argv) {
    int want = 20;
    for (int i = 0; i < argc; i++)
        if (!strcmp(argv[i], "-n") && i + 1 < argc) want = atoi(argv[++i]);
    if (want <= 0) want = 20;
    records_t r = load_records();
    int *pick = calloc((size_t)(r.n ? r.n : 1), sizeof *pick);
    int np = 0;
    for (int i = r.n - 1; i >= 0 && np < want; i--) {
        const char *d = jstr(r.v[i], "decision");
        if (!strcmp(d, "allow") || !strcmp(d, "note")) continue;
        pick[np++] = i;
    }
    if (!np) printf("No decisions yet: nothing has been blocked, warned about or noticed.\n");
    for (int k = np - 1; k >= 0; k--) {
        int i = pick[k];
        const cJSON *o = r.v[i];
        char when[32];
        local_time(jstr(o, "ts"), when, sizeof when);
        char dec[16];
        kai_strlcpy(dec, jstr(o, "decision"), sizeof dec);
        for (char *c = dec; *c; c++) *c = (char)(*c >= 'a' && *c <= 'z' ? *c - 32 : *c);
        const char *tool = jstr(o, "tool");
        printf("%s  %-11s  %-6s  %s%s%s\n", when, agent_name(o), dec, tool, *tool ? "  " : "",
               jstr(o, "rule"));
        const char *target = jstr(o, "target");
        if (*target) {
            printf("    ");
            int col = 0;
            for (const char *c = target; *c && col < 110; c++, col++) putchar(*c == '\n' ? ' ' : *c);
            printf("%s\n", strlen(target) > 110 ? "…" : "");
        }
        if (*jstr(o, "detail")) printf("    %s\n", jstr(o, "detail"));
        const cJSON *f = follow_up_of(&r, i);
        if (f) printf("    → %s\n", jstr(f, "detail"));
        printf("    id %.10s\n\n", jstr(o, "h"));
    }
    free(pick);
    free_records(&r);
    return 0;
}

int kai_cmd_log_show(int argc, char **argv) { return log_show(argc, argv); }

/* ---------- false-positive reports ---------- */

static void url_encode(sb_t *b, const char *s) {
    static const char *hex = "0123456789ABCDEF";
    for (const unsigned char *c = (const unsigned char *)s; *c; c++) {
        if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') ||
            strchr("-_.~", *c)) {
            sb_add(b, (const char *)c, 1);
        } else {
            char e[3] = {'%', hex[*c >> 4], hex[*c & 15]};
            sb_add(b, e, 3);
        }
    }
}

int kai_cmd_report(int argc, char **argv) {
    const char *id = NULL;
    int json = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!id) id = argv[i];
    }
    if (!id || strlen(id) < 6) {
        fprintf(stderr, "usage: kai report <record id> [--json]   (ids: kai log show)\n");
        return 2;
    }
    records_t r = load_records();
    const cJSON *o = NULL;
    for (int i = r.n - 1; i >= 0 && !o; i--)
        if (strncmp(jstr(r.v[i], "h"), id, strlen(id)) == 0) o = r.v[i];
    if (!o) {
        fprintf(stderr, "kai report: no record %s in the audit log\n", id);
        free_records(&r);
        return 1;
    }

    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    const char *rule = jstr(o, "rule"), *target = jstr(o, "target");
    /* A fence the excerpt can't close early. */
    const char *fence = strstr(target, "```") ? "~~~~" : "```";

    sb_t body;
    sb_init(&body);
    sb_addf(&body, "Kai %s something that wasn't a threat.\n\n", !strcmp(jstr(o, "decision"), "warn") ? "warned about" : "blocked");
    sb_addf(&body, "- Rule: `%s`\n", rule);
    sb_addf(&body, "- Decision: %s (%s, %s%s%s)\n", jstr(o, "decision"), agent_name(o), jstr(o, "event"),
            *jstr(o, "tool") ? ", " : "", jstr(o, "tool"));
    sb_addf(&body, "- Reason: %s\n", jstr(o, "detail"));
    if (*jstr(o, "match")) sb_addf(&body, "- Matched: `%s`\n", jstr(o, "match"));
    sb_addf(&body, "- Kai %s, policy: %s\n\n", KAI_VERSION, p ? kai_policy_source(p) : "error");
    if (*target)
        sb_addf(&body, "What was %s (secrets already hidden by Kai; check it before sharing):\n\n%s\n%s\n%s\n\n",
                !strcmp(jstr(o, "decision"), "warn") ? "flagged" : "blocked", fence, target, fence);
    else
        sb_adds(&body, "(No excerpt was recorded: `audit_context` is off or detection was disabled.)\n\n");
    sb_adds(&body, "What I was doing:\n\n");
    char *text = sb_take(&body);
    kai_policy_free(p);

    char dir[1200], path[1400], stamp[32];
    snprintf(dir, sizeof dir, "%s/reports", kai_home());
    mkdir(kai_home(), 0700);
    mkdir(dir, 0700);
    time_t now = time(NULL);
    struct tm lt;
    localtime_r(&now, &lt);
    strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &lt);
    char safe[48];
    size_t n = 0;
    for (const char *c = rule; *c && n < sizeof safe - 1; c++)
        safe[n++] = (*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '_' ? *c : '-';
    safe[n] = '\0';
    snprintf(path, sizeof path, "%s/%s-%s.md", dir, stamp, n ? safe : "report");
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "kai report: cannot write %s\n", path);
        free(text);
        free_records(&r);
        return 1;
    }
    fprintf(f, "# False positive: %s\n\n%s", rule, text);
    fclose(f);

    char title[160];
    snprintf(title, sizeof title, "False positive: %s", rule);
    sb_t url;
    sb_init(&url);
    sb_adds(&url, REPORT_REPO "/issues/new?labels=false-positive&title=");
    url_encode(&url, title);
    sb_adds(&url, "&body=");
    url_encode(&url, text);
    char *u = sb_take(&url);

    if (json) {
        cJSON *out = cJSON_CreateObject();
        cJSON_AddStringToObject(out, "path", path);
        cJSON_AddStringToObject(out, "issue_url", u);
        char *s = cJSON_PrintUnformatted(out);
        printf("%s\n", s);
        free(s);
        cJSON_Delete(out);
    } else {
        printf("Report written to %s\n\n"
               "Review it, then open this link to file it on GitHub (nothing is sent until you do):\n%s\n",
               path, u);
    }
    free(u);
    free(text);
    free_records(&r);
    return 0;
}

/* kai why <event-id>: explain one decision in plain words (read-only; the
 * record is already secret-redacted). No grant capability. (M0.5) */
int kai_cmd_why(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: kai why <event-id>   (ids from: kai denials)\n"); return 2; }
    const char *id = argv[0];
    size_t idlen = strlen(id);
    records_t r = load_records();
    const cJSON *hit = NULL;
    for (int i = r.n - 1; i >= 0; i--) {              /* newest first */
        if (strncmp(jstr(r.v[i], "h"), id, idlen) == 0) { hit = r.v[i]; break; }
    }
    if (!hit) { fprintf(stderr, "kai why: no record starting with '%s'\n", id); free_records(&r); return 1; }
    const char *match = jstr(hit, "match"), *target = jstr(hit, "target"), *detail = jstr(hit, "detail");
    printf("%s  %s  %s\n", jstr(hit, "ts"), agent_name(hit), jstr(hit, "decision"));
    printf("  wall:     %s\n", jstr(hit, "source"));
    if (*target) printf("  resource: %s\n", target);
    printf("  reason:   %s\n", jstr(hit, "rule"));
    if (*match) printf("  matched:  %s\n", match);
    if (*detail) printf("  detail:   %s\n", detail);
    free_records(&r);
    return 0;
}

/* kai denials [-n N] [--source net|storage]: recent blocks/would-blocks with
 * their event ids, so the user can `kai why <id>` (read-only). (M0.5) */
int kai_cmd_denials(int argc, char **argv) {
    int n = 20;
    const char *src = NULL;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--source") && i + 1 < argc) src = argv[++i];
    }
    records_t r = load_records();
    int shown = 0;
    printf("%-10s  %-20s  %-11s  %-11s  %-18s  %s\n", "id", "when", "agent", "decision", "reason", "resource");
    for (int i = r.n - 1; i >= 0 && shown < n; i--) {
        const char *dec = jstr(r.v[i], "decision");
        if (strcmp(dec, "block") && strcmp(dec, "would-block")) continue;
        if (src && strcmp(jstr(r.v[i], "source"), !strcmp(src, "net") ? "network" : src)) continue;
        char sid[11]; snprintf(sid, sizeof sid, "%.10s", jstr(r.v[i], "h"));
        printf("%-10s  %-20s  %-11s  %-11s  %-18s  %s\n", sid, jstr(r.v[i], "ts"),
               agent_name(r.v[i]), dec, jstr(r.v[i], "rule"), jstr(r.v[i], "target"));
        shown++;
    }
    if (!shown) printf("(no denials recorded)\n");
    free_records(&r);
    return 0;
}
