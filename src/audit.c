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

/* Read the last record's chain hash from the log (field "h":"..."). */
static void last_hash(const char *path, char out[65]) {
    kai_strlcpy(out, "genesis", 65);
    FILE *f = fopen(path, "rb");
    if (!f) return;
    char line[8192], keep[8192];
    keep[0] = '\0';
    while (fgets(line, sizeof line, f))
        if (line[0]) kai_strlcpy(keep, line, sizeof keep);
    fclose(f);
    char *p = strstr(keep, "\"h\":\"");
    if (p) {
        p += 5;
        char *e = strchr(p, '"');
        if (e && (size_t)(e - p) < 65) { memcpy(out, p, (size_t)(e - p)); out[e - p] = '\0'; }
    }
}

int kai_audit(const char *source, const char *event, const char *decision,
              const char *rule, const char *detail) {
    ensure_home();
    const char *path = kai_audit_path();
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return -1;
    flock(fd, LOCK_EX);

    char prev[65];
    last_hash(path, prev);

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
    flock(fd, LOCK_UN);
    close(fd);
    return (w == (ssize_t)len) ? 0 : -1;
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
