/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * A small shell-command reader for hook checks. It does not run or expand
 * anything; it splits a command line the way a POSIX shell would, so checks
 * can look at what is actually executed instead of matching raw text:
 *
 *   - quotes and escapes are resolved ('~/.ss'"h"/id_rsa is ~/.ssh/id_rsa)
 *   - simple commands are split on ; & | && || ( ) { } and newlines
 *   - $(...) and `...` are read as commands too
 *   - sh -c '...', bash -c, zsh -c and eval '...' are read recursively
 *   - heredoc bodies are reported as text, or read as commands when they
 *     feed a shell (bash <<EOF)
 *
 * It is a tripwire, not a sandbox: anything a shell can compute at run time
 * (variables, arithmetic, files it creates) is out of reach by design.
 */
#include "internal.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 4
#define MAX_HEREDOCS 8

typedef struct {
    char **v;
    int n, cap;
} words_t;

static void words_push(words_t *w, char *s) {
    if (w->n >= w->cap) {
        int nc = w->cap ? w->cap * 2 : 8;
        char **nv = realloc(w->v, (size_t)nc * sizeof *nv);
        if (!nv) { free(s); return; }
        w->v = nv;
        w->cap = nc;
    }
    w->v[w->n++] = s;
}

static void words_clear(words_t *w) {
    for (int i = 0; i < w->n; i++) free(w->v[i]);
    w->n = 0;
}

static const char *base(const char *w) {
    const char *s = strrchr(w, '/');
    return s ? s + 1 : w;
}

static int is_shell(const char *w) {
    const char *b = base(w);
    return !strcmp(b, "sh") || !strcmp(b, "bash") || !strcmp(b, "zsh") || !strcmp(b, "dash") ||
           !strcmp(b, "ksh");
}

typedef struct {
    kai_shell_cmd_fn on_cmd;
    kai_shell_text_fn on_text;
    void (*on_sep)(int pipe, void *ud); /* after each command: piped into the next? */
    void *ud;
} walker_t;

static void walk(const walker_t *wk, const char *s, size_t len, int depth);

/* Report one simple command, then look inside sh -c / eval. */
static void emit(const walker_t *wk, words_t *argv, int depth) {
    if (!argv->n) return;
    if (wk->on_cmd) wk->on_cmd(argv->v, argv->n, wk->ud);
    if (depth >= MAX_DEPTH) return;
    /* skip VAR=value prefixes and wrappers to find the real command */
    int i = 0;
    while (i < argv->n && strchr(argv->v[i], '=') && argv->v[i][0] != '=' && argv->v[i][0] != '-') i++;
    if (i >= argv->n) return;
    const char *cmd = base(argv->v[i]);
    if (is_shell(cmd)) {
        for (int k = i + 1; k + 1 < argv->n; k++)
            if (argv->v[k][0] == '-' && strchr(argv->v[k], 'c')) {
                walk(wk, argv->v[k + 1], strlen(argv->v[k + 1]), depth + 1);
                break;
            }
    } else if (!strcmp(cmd, "eval")) {
        sb_t b;
        sb_init(&b);
        for (int k = i + 1; k < argv->n; k++) { if (k > i + 1) sb_adds(&b, " "); sb_adds(&b, argv->v[k]); }
        char *t = sb_take(&b);
        walk(wk, t, strlen(t), depth + 1);
        free(t);
    }
}

/* Find the end of a $( ... ) starting just after "$(": returns index of the
 * matching ')' or len. Quotes inside are skipped. */
static size_t match_paren(const char *s, size_t i, size_t len) {
    int d = 1;
    for (; i < len; i++) {
        char c = s[i];
        if (c == '\\' && i + 1 < len) { i++; continue; }
        if (c == '\'') { while (++i < len && s[i] != '\'') {} continue; }
        if (c == '"') { while (++i < len && s[i] != '"') if (s[i] == '\\') i++; continue; }
        if (c == '(') d++;
        if (c == ')' && --d == 0) return i;
    }
    return len;
}

static void walk(const walker_t *wk, const char *s, size_t len, int depth) {
    words_t argv = {0};
    sb_t word;
    sb_init(&word);
    int in_word = 0;
    struct { char delim[64]; int strip_tabs, shell; } hd[MAX_HEREDOCS];
    int nhd = 0;

#define END_WORD()                                         \
    do {                                                   \
        if (in_word) { words_push(&argv, sb_take(&word)); in_word = 0; } \
    } while (0)
#define END_CMD(pipe)                                      \
    do {                                                   \
        END_WORD();                                        \
        int had_ = argv.n > 0;                             \
        emit(wk, &argv, depth);                            \
        words_clear(&argv);                                \
        if (had_ && wk->on_sep) wk->on_sep(pipe, wk->ud);  \
    } while (0)

    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (c == '\\') {
            if (i + 1 < len && s[i + 1] == '\n') { i++; continue; } /* line continuation */
            if (i + 1 < len) { sb_add(&word, &s[i + 1], 1); i++; in_word = 1; }
            continue;
        }
        if (c == '\'') {
            size_t j = i + 1;
            while (j < len && s[j] != '\'') j++;
            sb_add(&word, s + i + 1, j - i - 1);
            in_word = 1;
            i = j;
            continue;
        }
        if (c == '"') {
            size_t j = i + 1;
            for (; j < len && s[j] != '"'; j++) {
                if (s[j] == '\\' && j + 1 < len && strchr("\"\\$`\n", s[j + 1])) {
                    if (s[j + 1] != '\n') sb_add(&word, &s[j + 1], 1);
                    j++;
                } else if (s[j] == '$' && j + 1 < len && s[j + 1] == '(') {
                    size_t e = match_paren(s, j + 2, len);
                    if (depth < MAX_DEPTH) walk(wk, s + j + 2, e - j - 2, depth + 1);
                    sb_add(&word, s + j, (e < len ? e + 1 : len) - j);
                    j = e;
                } else {
                    sb_add(&word, &s[j], 1);
                }
            }
            in_word = 1;
            i = j;
            continue;
        }
        if (c == '$' && i + 1 < len && s[i + 1] == '(') {
            size_t e = match_paren(s, i + 2, len);
            if (depth < MAX_DEPTH) walk(wk, s + i + 2, e - i - 2, depth + 1);
            sb_add(&word, s + i, (e < len ? e + 1 : len) - i);
            in_word = 1;
            i = e;
            continue;
        }
        if (c == '`') {
            size_t j = i + 1;
            while (j < len && s[j] != '`') { if (s[j] == '\\') j++; j++; }
            if (depth < MAX_DEPTH) walk(wk, s + i + 1, (j < len ? j : len) - i - 1, depth + 1);
            sb_add(&word, s + i, (j < len ? j + 1 : len) - i);
            in_word = 1;
            i = j;
            continue;
        }
        if (c == '#' && !in_word) { /* comment to end of line */
            while (i + 1 < len && s[i + 1] != '\n') i++;
            continue;
        }
        if (c == '<' && i + 1 < len && s[i + 1] == '<' && !(i + 2 < len && s[i + 2] == '<')) {
            /* heredoc: remember the delimiter; the body starts at the next newline */
            END_WORD();
            size_t j = i + 2;
            int strip = 0;
            if (j < len && s[j] == '-') { strip = 1; j++; }
            while (j < len && (s[j] == ' ' || s[j] == '\t')) j++;
            char d[64];
            size_t dn = 0;
            while (j < len && !isspace((unsigned char)s[j]) && !strchr(";&|<>()", s[j])) {
                if (s[j] != '\'' && s[j] != '"' && s[j] != '\\' && dn < sizeof d - 1) d[dn++] = s[j];
                j++;
            }
            d[dn] = '\0';
            if (dn && nhd < MAX_HEREDOCS) {
                kai_strlcpy(hd[nhd].delim, d, sizeof hd[nhd].delim);
                hd[nhd].strip_tabs = strip;
                hd[nhd].shell = argv.n > 0 && is_shell(argv.v[0]);
                nhd++;
            }
            i = j - 1;
            continue;
        }
        if (c == '\n') {
            END_CMD(0);
            /* read pending heredoc bodies */
            size_t p = i + 1;
            for (int h = 0; h < nhd; h++) {
                size_t body = p;
                while (p < len) {
                    size_t e = p;
                    while (e < len && s[e] != '\n') e++;
                    size_t ls = p;
                    if (hd[h].strip_tabs) while (ls < e && s[ls] == '\t') ls++;
                    if (e - ls == strlen(hd[h].delim) && !strncmp(s + ls, hd[h].delim, e - ls)) {
                        size_t blen = p - body;
                        if (hd[h].shell && depth < MAX_DEPTH) walk(wk, s + body, blen, depth + 1);
                        else if (wk->on_text) {
                            char *t = malloc(blen + 1);
                            if (t) { memcpy(t, s + body, blen); t[blen] = '\0'; wk->on_text(t, wk->ud); free(t); }
                        }
                        p = e < len ? e + 1 : len;
                        goto next_heredoc;
                    }
                    p = e < len ? e + 1 : len;
                }
                /* unterminated: the rest is the body */
                if (wk->on_text) {
                    char *t = malloc(len - body + 1);
                    if (t) { memcpy(t, s + body, len - body); t[len - body] = '\0'; wk->on_text(t, wk->ud); free(t); }
                }
            next_heredoc:;
            }
            if (nhd) { i = p - 1; nhd = 0; }
            continue;
        }
        if (c == ' ' || c == '\t') { END_WORD(); continue; }
        if (strchr(";&|(){}", c)) {
            /* a single | (or |&) pipes into the next command; || and ; don't */
            int pipe = c == '|' && !(i + 1 < len && s[i + 1] == '|') && !(i > 0 && s[i - 1] == '|');
            END_CMD(pipe);
            continue;
        }
        if (c == '<' || c == '>') { END_WORD(); continue; } /* redirection: target is the next word */
        sb_add(&word, &c, 1);
        in_word = 1;
    }
    END_CMD(0);
    words_clear(&argv);
    free(argv.v);
    sb_free(&word);
#undef END_WORD
#undef END_CMD
}

void kai_shell_walk(const char *cmd, kai_shell_cmd_fn on_cmd, kai_shell_text_fn on_text, void *ud) {
    if (!cmd) return;
    walker_t wk = {on_cmd, on_text, NULL, ud};
    walk(&wk, cmd, strlen(cmd), 0);
}

int kai_shell_command_start(char **argv, int argc) {
    /* VAR=value prefixes, then wrappers that run the next word */
    static const char *const WRAPPERS[] = {"sudo", "env", "exec", "command", "nohup", "time",
                                           "nice", "timeout", "xargs", "doas", "builtin"};
    int i = 0;
    for (;;) {
        while (i < argc && strchr(argv[i], '=') && argv[i][0] != '-' && argv[i][0] != '=') i++;
        if (i >= argc) return argc;
        const char *b = base(argv[i]);
        int wrapped = 0;
        for (size_t w = 0; w < sizeof WRAPPERS / sizeof WRAPPERS[0]; w++)
            if (strcmp(b, WRAPPERS[w]) == 0) wrapped = 1;
        if (!wrapped) return i;
        i++;
        while (i < argc && argv[i][0] == '-') i++;                      /* wrapper options */
        if (strcmp(b, "timeout") == 0 && i < argc) i++;                  /* its duration */
    }
}

/* ---- command view ----
 * What upload rules are matched against: one line per pipeline, each command
 * as its name (no path, no VAR= or sudo/env/... in front) and its arguments,
 * piped commands joined by " | ". Heredoc bodies and comments are left out,
 * so text that only mentions a command isn't taken for running it. Text
 * echoed into a shell (echo '...' | sh) is read as commands too. */
typedef struct {
    sb_t out;
    int open;       /* a command is on the current line, not yet ended */
    char *echoed;   /* arguments of the last echo/printf in this pipeline */
    char *extra[4]; /* echoed text that was piped into a shell */
    int nextra;
} view_t;

static void view_cmd(char **argv, int argc, void *ud) {
    view_t *v = ud;
    int i = kai_shell_command_start(argv, argc);
    if (i >= argc) return;
    if (v->open) sb_adds(&v->out, "\n"); /* a command read inside another (sh -c, $()) */
    const char *name = base(argv[i]);
    sb_adds(&v->out, name);
    for (int k = i + 1; k < argc; k++) {
        sb_adds(&v->out, " ");
        for (const char *c = argv[k]; *c; c++) sb_add(&v->out, (*c == '\n' || *c == '\r') ? " " : c, 1);
    }
    v->open = 1;
    /* echo '...' | sh: a shell with no -c and no script reads the echoed text */
    int reads_stdin = is_shell(name);
    for (int k = i + 1; k < argc && reads_stdin; k++)
        if (argv[k][0] != '-' || strchr(argv[k], 'c')) reads_stdin = 0;
    if (reads_stdin && v->echoed && v->nextra < 4) {
        v->extra[v->nextra++] = v->echoed;
        v->echoed = NULL;
    }
    free(v->echoed);
    v->echoed = NULL;
    if (!strcmp(name, "echo") || !strcmp(name, "printf")) {
        sb_t b;
        sb_init(&b);
        for (int k = i + 1; k < argc; k++) { if (k > i + 1) sb_adds(&b, " "); sb_adds(&b, argv[k]); }
        v->echoed = sb_take(&b);
    }
}

static void view_sep(int pipe, void *ud) {
    view_t *v = ud;
    sb_adds(&v->out, pipe ? " | " : "\n");
    v->open = 0;
    if (!pipe) { free(v->echoed); v->echoed = NULL; }
}

char *kai_shell_view(const char *cmd) {
    view_t v;
    memset(&v, 0, sizeof v);
    sb_init(&v.out);
    if (cmd) {
        walker_t wk = {view_cmd, NULL, view_sep, &v};
        walk(&wk, cmd, strlen(cmd), 0);
        int n = v.nextra;
        v.nextra = 4; /* echoed text inside echoed text isn't followed further */
        for (int k = 0; k < n; k++) {
            if (v.open) { sb_adds(&v.out, "\n"); v.open = 0; }
            walk(&wk, v.extra[k], strlen(v.extra[k]), 1);
            free(v.extra[k]);
        }
    }
    free(v.echoed);
    return sb_take(&v.out);
}
