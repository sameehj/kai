/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

void sb_init(sb_t *b) { memset(b, 0, sizeof *b); }

static int sb_grow(sb_t *b, size_t need) {
    if (b->oom) return 0;
    if (b->len + need + 1 <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + need + 1) {
        if (cap > ((size_t)-1) / 2) { b->oom = 1; return 0; }
        cap *= 2;
    }
    char *np = realloc(b->p, cap);
    if (!np) { b->oom = 1; return 0; }
    b->p = np;
    b->cap = cap;
    return 1;
}

void sb_add(sb_t *b, const char *s, size_t n) {
    if (!n || !sb_grow(b, n)) return;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = '\0';
}

void sb_adds(sb_t *b, const char *s) { if (s) sb_add(b, s, strlen(s)); }

void sb_addf(sb_t *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char tmp[512];
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof tmp) { sb_add(b, tmp, (size_t)n); return; }
    if (!sb_grow(b, (size_t)n)) return;
    va_start(ap, fmt);
    vsnprintf(b->p + b->len, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)n;
}

char *sb_take(sb_t *b) {
    char *r = b->p;
    if (!r || b->oom) { free(r); r = strdup(""); }
    memset(b, 0, sizeof *b);
    return r;
}

void sb_free(sb_t *b) { free(b->p); memset(b, 0, sizeof *b); }

void kai_strlcpy(char *dst, const char *src, size_t n) {
    if (!n) return;
    size_t i = 0;
    if (src)
        for (; i + 1 < n && src[i]; i++) dst[i] = src[i];
    dst[i] = '\0';
}

char *kai_read_stream(FILE *f, size_t max, size_t *outlen) {
    sb_t b;
    sb_init(&b);
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
        if (b.len + n > max) { sb_free(&b); return NULL; }
        sb_add(&b, buf, n);
    }
    if (outlen) *outlen = b.len;
    return sb_take(&b);
}

char *kai_read_file(const char *path, size_t max, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *r = kai_read_stream(f, max, outlen);
    fclose(f);
    return r;
}

static const char *home_dir(void) {
    const char *h = getenv("HOME");
    return (h && *h) ? h : "/";
}

char *kai_expand_home(const char *path) {
    sb_t b;
    sb_init(&b);
    const char *h = home_dir();
    if (path[0] == '~' && (path[1] == '/' || path[1] == '\0')) {
        sb_adds(&b, h);
        path++;
    } else if (strncmp(path, "${HOME}", 7) == 0) {
        sb_adds(&b, h);
        path += 7;
    } else if (strncmp(path, "$HOME", 5) == 0 &&
               (path[5] == '/' || path[5] == '\0')) {
        sb_adds(&b, h);
        path += 5;
    }
    sb_adds(&b, path);
    return sb_take(&b);
}

/* Make an absolute path and collapse "." and ".." without touching disk. */
char *kai_normalize_path(const char *path, const char *cwd) {
    char *exp = kai_expand_home(path);
    sb_t raw;
    sb_init(&raw);
    if (exp[0] != '/') {
        if (cwd && *cwd) sb_adds(&raw, cwd);
        else {
            char buf[PATH_MAX];
            if (getcwd(buf, sizeof buf)) sb_adds(&raw, buf);
        }
        sb_adds(&raw, "/");
    }
    sb_adds(&raw, exp);
    free(exp);
    char *in = sb_take(&raw);

    /* split into components, apply . and .. */
    size_t n = strlen(in);
    char **parts = calloc(n / 2 + 2, sizeof *parts);
    int np = 0;
    char *save = NULL;
    for (char *tok = strtok_r(in, "/", &save); tok; tok = strtok_r(NULL, "/", &save)) {
        if (strcmp(tok, ".") == 0) continue;
        if (strcmp(tok, "..") == 0) { if (np) np--; continue; }
        parts[np++] = tok;
    }
    sb_t out;
    sb_init(&out);
    if (!np) sb_adds(&out, "/");
    for (int i = 0; i < np; i++) { sb_adds(&out, "/"); sb_adds(&out, parts[i]); }
    free(parts);
    free(in);
    return sb_take(&out);
}

const char *kai_exe_path(void) {
    static char buf[PATH_MAX];
    if (buf[0]) return buf;
#ifdef __APPLE__
    char tmp[PATH_MAX];
    uint32_t size = sizeof tmp;
    if (_NSGetExecutablePath(tmp, &size) == 0 && realpath(tmp, buf)) return buf;
#else
    ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n > 0) { buf[n] = '\0'; return buf; }
#endif
    kai_strlcpy(buf, "kai", sizeof buf);
    return buf;
}

/* Dev-sandbox guard (S0): abort if a test or dev run would touch the real Kai
 * home. Tests MUST set KAI_HOME to a throwaway dir; running against the user's
 * real home can corrupt their policy, grants and audit log. Call this at the
 * top of every test main() right after setting KAI_HOME. */
/* 1 if the active Kai home is (or would default to) the user's real ~/.kai:
 * either KAI_HOME is unset/empty, or it resolves to the real home. */
int kai_home_is_real(void) {
    const char *env = getenv("KAI_HOME");
    if (!env || !*env) return 1;
    char *real = kai_expand_home("~/.kai");
    int same = real && strcmp(kai_home(), real) == 0;
    free(real);
    return same;
}

void kai_require_sandbox_home(void) {
    if (kai_home_is_real()) {
        fprintf(stderr,
                "kai: REFUSING to run against the real Kai home (%s).\n"
                "Set KAI_HOME to a throwaway sandbox dir (e.g. /tmp/kai-dev) first.\n",
                kai_home());
        abort();
    }
}
