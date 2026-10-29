/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"
#include <ctype.h>
#include <sys/time.h>

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

void kai_sha256_hex(const void *data, size_t n, char out[65]);

const char *kai_home(void) {
    static char buf[1024];
    if (buf[0]) return buf;
    const char *env = getenv("KAI_HOME");
    if (env && *env) { kai_strlcpy(buf, env, sizeof buf); return buf; }
    char *h = kai_expand_home("~/.kai");
    kai_strlcpy(buf, h, sizeof buf);
    free(h);
    return buf;
}

const char *kai_audit_path(void) {
    static char buf[1100];
    if (!buf[0]) snprintf(buf, sizeof buf, "%s/audit.log", kai_home());
    return buf;
}

static void ensure_home(void) {
    mkdir(kai_home(), 0700);
}

/* JSON-escape a field into b (no secrets should ever be passed here). */
static void esc(sb_t *b, const char *s) {
    sb_add(b, "\"", 1);
    for (const char *c = s ? s : ""; *c; c++) {
        switch (*c) {
        case '"': sb_adds(b, "\\\""); break;
        case '\\': sb_adds(b, "\\\\"); break;
        case '\n': sb_adds(b, "\\n"); break;
        case '\r': sb_adds(b, "\\r"); break;
        case '\t': sb_adds(b, "\\t"); break;
        default:
            if ((unsigned char)*c < 0x20) sb_addf(b, "\\u%04x", *c);
            else sb_add(b, c, 1);
        }
    }
    sb_add(b, "\"", 1);
}

/* Read the last record's chain hash ("h":"...") from the open log. Only the
 * file's tail is read, so appending stays fast however long the log gets
 * (it used to re-read the whole file on every write). */
static void last_hash(int fd, char out[65]) {
    kai_strlcpy(out, "genesis", 65);
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) return;
    off_t want = st.st_size < 65536 ? st.st_size : 65536;
    char *buf = malloc((size_t)want + 1);
    if (!buf) return;
    ssize_t n = pread(fd, buf, (size_t)want, st.st_size - want);
    if (n <= 0) { free(buf); return; }
    buf[n] = '\0';
    /* the last occurrence of "h":" is in the last complete record */
    const char *key = "\"h\":\"", *hit = NULL;
    for (char *q = strstr(buf, key); q; q = strstr(q + 1, key)) hit = q;
    if (hit) {
        hit += 5;
        const char *e = strchr(hit, '"');
        if (e && (size_t)(e - hit) < 65) { memcpy(out, hit, (size_t)(e - hit)); out[e - hit] = '\0'; }
    }
    free(buf);
}

/* Add ,"key":"value" if value is set, cut to max bytes on a UTF-8 boundary. */
static void opt_field(sb_t *b, const char *key, const char *value, size_t max) {
    if (!value || !*value) return;
    size_t n = strlen(value);
    char *cut = NULL;
    if (n > max) {
        n = max;
        while (n && ((unsigned char)value[n] & 0xC0) == 0x80) n--;
        cut = malloc(n + 4);
        if (!cut) return;
        memcpy(cut, value, n);
        memcpy(cut + n, "\xE2\x80\xA6", 4); /* … */
        value = cut;
    }
    sb_addf(b, ",\"%s\":", key);
    esc(b, value);
    free(cut);
}

/* Write one hash-chained record to fd, which the caller holds locked. */
static int append_record(int fd, const kai_audit_entry *e) {
    char prev[65];
    last_hash(fd, prev);

    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    gmtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", &tmv);

    /* body without the chain hash */
    sb_t body;
    sb_init(&body);
    sb_adds(&body, "{\"ts\":"); esc(&body, ts);
    sb_adds(&body, ",\"source\":"); esc(&body, e->source);
    sb_adds(&body, ",\"event\":"); esc(&body, e->event);
    sb_adds(&body, ",\"decision\":"); esc(&body, e->decision);
    sb_adds(&body, ",\"rule\":"); esc(&body, e->rule ? e->rule : "");
    sb_adds(&body, ",\"detail\":"); esc(&body, e->detail ? e->detail : "");
    opt_field(&body, "tool", e->tool, 64);
    opt_field(&body, "target", e->target, KAI_AUDIT_TARGET_MAX);
    opt_field(&body, "match", e->match, 160);
    opt_field(&body, "session", e->session, 128);
    opt_field(&body, "cwd", e->cwd, 512);
    opt_field(&body, "identity", e->identity, 160);
    sb_adds(&body, ",\"prev\":"); esc(&body, prev);
    char *bodystr = sb_take(&body);

    /* chain hash = sha256(prev + body) */
    sb_t chain;
    sb_init(&chain);
    sb_adds(&chain, prev);
    sb_adds(&chain, bodystr);
    char *chainin = sb_take(&chain);
    char hash[65];
    kai_sha256_hex(chainin, strlen(chainin), hash);
    free(chainin);

    sb_t line;
    sb_init(&line);
    sb_adds(&line, bodystr);
    sb_addf(&line, ",\"h\":\"%s\"}\n", hash);
    char *out = sb_take(&line);
    free(bodystr);

    size_t len = strlen(out);
    ssize_t w = write(fd, out, len);
    free(out);
    return (w == (ssize_t)len) ? 0 : -1;
}

/* Size at which the log is rotated to audit.log.1 (one old file is kept). */
static off_t max_log_bytes(void) {
    const char *e = getenv("KAI_AUDIT_MAX_BYTES");
    long v = e ? strtol(e, NULL, 10) : 0;
    return v > 0 ? (off_t)v : (off_t)8 * 1024 * 1024;
}

static int open_locked(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);
    return fd;
}

int kai_audit(const char *source, const char *event, const char *decision,
              const char *rule, const char *detail) {
    kai_audit_entry e = {source, event, decision, rule, detail, NULL, NULL, NULL, NULL, NULL, NULL};
    return kai_audit_write(&e);
}

void kai_denial_audit(const char *source, const char *agent, const char *decision,
                      const char *resource, const char *op, const char *reason_code,
                      const char *matched_rule, const char *detail) {
    kai_denial_audit_ex(source, agent, decision, resource, op, reason_code, matched_rule, detail,
                        NULL, NULL);
}

void kai_denial_audit_ex(const char *source, const char *agent, const char *decision,
                         const char *resource, const char *op, const char *reason_code,
                         const char *matched_rule, const char *detail,
                         const char *session, const char *identity) {
    kai_audit_entry e;
    memset(&e, 0, sizeof e);
    e.source = source;
    e.event = agent;
    e.decision = decision ? decision : "block";
    e.rule = reason_code;                 /* a reason CODE, never the host/path */
    e.detail = detail;
    e.tool = op;
    e.target = resource;                  /* host:port or path */
    e.match = (matched_rule && *matched_rule) ? matched_rule : NULL; /* only when a rule matched */
    e.session = (session && *session) ? session : NULL;
    e.identity = (identity && *identity) ? identity : NULL;
    kai_audit_write(&e);
}

/* Health probes (kai status) exercise the hooks with a synthetic request; what
 * they decide is not something that happened, so it isn't recorded. */
static int g_suppress;
void kai_audit_suppress(int on) { g_suppress = on; }
int kai_audit_suppressed(void) { return g_suppress; }

/* A2: a real hook call (not a health probe) stamps <kai home>/hookseen/<agent>
 * so `kai status` can say when an agent last ran Kai's checks. Outside the
 * control store, so the signed hook may write it from an agent's tree; agents
 * themselves can't write anything under Kai's home. */
void kai_hook_seen(const char *agent) {
    if (!agent || !*agent || strchr(agent, '/') || g_suppress) return;
    char dir[1200], path[1300];
    snprintf(dir, sizeof dir, "%s/hookseen", kai_home());
    mkdir(kai_home(), 0700);
    mkdir(dir, 0700);
    snprintf(path, sizeof path, "%s/%s", dir, agent);
    int fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) { futimes(fd, NULL); close(fd); }
}

long long kai_hook_last_seen(const char *agent) {
    char path[1300];
    snprintf(path, sizeof path, "%s/hookseen/%s", kai_home(), agent ? agent : "");
    struct stat st;
    return stat(path, &st) == 0 ? (long long)st.st_mtime : 0;
}

/* Fix 1: the per-day counter behind "Kai kept 3 secrets private today". One
 * byte per meaningful record, appended to <kai home>/daily/<local date> (an
 * O_APPEND write this small is atomic, so hooks and walls can share it). It is
 * independent of the log, so rotation doesn't reset it. 's' = a secret kept
 * private (a redaction, or a block of a protected file or a secret), 'b' =
 * another block. Telemetry, a remembered Keep blocked, the QUIC fallback and
 * grant bookkeeping are never counted. */
static char daily_kind(const kai_audit_entry *e) {
    const char *d = e->decision ? e->decision : "", *det = e->detail ? e->detail : "";
    const char *src = e->source ? e->source : "", *rule = e->rule ? e->rule : "";
    if (!strcmp(src, "grant") || !strncmp(det, "telemetry to ", 13) || !strncmp(det, "kept blocked", 12) ||
        (!strcmp(src, "network") && e->target && !strcmp(e->target, "QUIC")))
        return 0;
    if (!strcmp(d, "redact") || !strcmp(d, "replace")) return 's';
    if (strcmp(d, "block") != 0) return 0;
    if (!strcmp(src, "storage") || !strncmp(rule, "secret", 6) || strstr(det, "protected")) return 's';
    return 'b';
}

static void daily_path(const char *date, char *out, size_t n) {
    char today[16];
    if (!date) {
        time_t now = time(NULL);
        struct tm tmv;
        localtime_r(&now, &tmv);
        strftime(today, sizeof today, "%Y-%m-%d", &tmv);
        date = today;
    }
    snprintf(out, n, "%s/daily/%s", kai_home(), date);
}

static void daily_count(const kai_audit_entry *e) {
    char k = daily_kind(e);
    if (!k) return;
    char dir[1100], fp[1200];
    snprintf(dir, sizeof dir, "%s/daily", kai_home());
    mkdir(dir, 0700);
    daily_path(NULL, fp, sizeof fp);
    int fd = open(fp, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    if (write(fd, &k, 1) != 1) { /* best effort: the log itself is the record */ }
    if (geteuid() == 0) {               /* a wall running as root: keep it the user's */
        struct stat hs;
        if (stat(kai_home(), &hs) == 0) { if (fchown(fd, hs.st_uid, hs.st_gid) != 0 || chown(dir, hs.st_uid, hs.st_gid) != 0) {} }
    }
    close(fd);
}

int kai_daily_counts(const char *date, int *secrets, int *other) {
    if (secrets) *secrets = 0;
    if (other) *other = 0;
    char fp[1200];
    daily_path(date, fp, sizeof fp);
    size_t n = 0;
    char *t = kai_read_file(fp, 64u << 20, &n);
    if (!t) return 0;
    for (size_t i = 0; i < n; i++) {
        if (t[i] == 's' && secrets) (*secrets)++;
        else if (t[i] == 'b' && other) (*other)++;
    }
    free(t);
    return 1;
}

int kai_audit_write(const kai_audit_entry *e) {
    if (g_suppress) return 0;
    ensure_home();
    const char *path = kai_audit_path();
    int fd = open_locked(path);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > max_log_bytes()) {
        /* Rotate. The new file starts its own chain, and its first record
         * names the hash the old file ended on, so the two still link up. */
        char ended[65];
        last_hash(fd, ended);
        char old[1200];
        snprintf(old, sizeof old, "%s.1", path);
        if (rename(path, old) == 0) {
            int nfd = open_locked(path);
            flock(fd, LOCK_UN);
            close(fd);
            fd = nfd;
            if (fd < 0) return -1;
            char note[200];
            snprintf(note, sizeof note, "previous log %s.1 ended with %s", "audit.log", ended);
            /* "allow": bookkeeping, not an event */
            kai_audit_entry r = {"kai", "rotate", "allow", "audit.log.1", note, NULL, NULL, NULL, NULL, NULL, NULL};
            append_record(fd, &r);
        }
    }

    int rc = append_record(fd, e);
    flock(fd, LOCK_UN);
    close(fd);
    if (rc == 0) daily_count(e);
    return rc;
}

/* A5: after a rotation the current log starts with a "rotate" record naming
 * the old log's last hash. Check audit.log.1 is intact and really ends there.
 * 1 = continues, 0 = no rotation recorded, -1 = broken/missing (err says). */
int kai_audit_verify_rotation(char *err, size_t errlen) {
    if (errlen) err[0] = '\0';
    size_t n = 0;
    char *cur = kai_read_file(kai_audit_path(), 64u << 20, &n);
    if (!cur) return 0;
    char *nl = strchr(cur, '\n'); if (nl) *nl = '\0';
    const char *m = strstr(cur, "\"event\":\"rotate\"");
    const char *e = m ? strstr(cur, "ended with ") : NULL;
    char want[65] = "";
    if (e) { e += 11; size_t k = 0; while (k < 64 && isxdigit((unsigned char)e[k])) { want[k] = e[k]; k++; } want[k] = '\0'; }
    free(cur);
    if (!m || !want[0]) return 0;
    char old[1200]; snprintf(old, sizeof old, "%s.1", kai_audit_path());
    int nlines = 0; char verr[256];
    FILE *f = fopen(old, "rb");
    if (!f) { snprintf(err, errlen, "audit.log.1 is missing (the current log says it ended with %.12s)", want); return -1; }
    fclose(f);
    if (kai_audit_verify(old, &nlines, verr, sizeof verr) != 0) { snprintf(err, errlen, "audit.log.1: %s", verr); return -1; }
    int fd = open(old, O_RDONLY);
    char last[65] = "";
    if (fd >= 0) { last_hash(fd, last); close(fd); }
    if (strcmp(last, want) != 0) {
        snprintf(err, errlen, "audit.log.1 ends with %.12s, but the current log says %.12s", last, want);
        return -1;
    }
    return 1;
}

int kai_audit_verify(const char *path, int *nlines, char *err, size_t errlen) {
    if (nlines) *nlines = 0;
    if (errlen) err[0] = '\0';
    const char *p = path ? path : kai_audit_path();
    FILE *f = fopen(p, "rb");
    if (!f) { snprintf(err, errlen, "cannot open %s", p); return -1; }

    char prev[65] = "genesis";
    char line[16384];
    int ln = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        size_t L = strlen(line);
        if (L && line[L - 1] == '\n') line[--L] = '\0';
        if (!L) continue;
        ln++;
        char *hp = strstr(line, ",\"h\":\"");
        if (!hp) { bad = ln; break; }
        char stored[65];
        char *hs = hp + 6;
        char *he = strchr(hs, '"');
        if (!he || (size_t)(he - hs) >= 65) { bad = ln; break; }
        memcpy(stored, hs, (size_t)(he - hs)); stored[he - hs] = '\0';
        size_t bodylen = (size_t)(hp - line); /* body is everything before ,"h" */
        sb_t chain; sb_init(&chain);
        sb_adds(&chain, prev);
        sb_add(&chain, line, bodylen);
        char *ci = sb_take(&chain);
        char calc[65];
        kai_sha256_hex(ci, strlen(ci), calc);
        free(ci);
        if (strcmp(calc, stored) != 0) { bad = ln; break; }
        kai_strlcpy(prev, stored, sizeof prev);
    }
    fclose(f);
    if (nlines) *nlines = ln;
    if (bad) { snprintf(err, errlen, "chain broken at record %d", bad); return -1; }
    return 0;
}
