/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"

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

/* Write one hash-chained record to fd, which the caller holds locked. */
static int append_record(int fd, const char *source, const char *event, const char *decision,
                         const char *rule, const char *detail) {
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
    sb_adds(&body, ",\"source\":"); esc(&body, source);
    sb_adds(&body, ",\"event\":"); esc(&body, event);
    sb_adds(&body, ",\"decision\":"); esc(&body, decision);
    sb_adds(&body, ",\"rule\":"); esc(&body, rule ? rule : "");
    sb_adds(&body, ",\"detail\":"); esc(&body, detail ? detail : "");
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
            append_record(fd, "kai", "rotate", "allow", "audit.log.1", note); /* "allow": bookkeeping, not an event */
        }
    }

    int rc = append_record(fd, source, event, decision, rule, detail);
    flock(fd, LOCK_UN);
    close(fd);
    return rc;
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
