/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

const char *kai_action_name(kai_action a) {
    switch (a) {
    case KAI_ACT_NONE: return "allow";
    case KAI_ACT_WARN: return "warn";
    case KAI_ACT_REPLACE: return "replace";
    case KAI_ACT_REDACT: return "redact";
    case KAI_ACT_BLOCK: return "block";
    }
    return "allow";
}

static void record(kai_report *rep, const char *rule, kai_action a) {
    if (!rep) return;
    for (int i = 0; i < rep->nhits; i++)
        if (strcmp(rep->hits[i].rule, rule) == 0) {
            rep->hits[i].count++;
            if (a > rep->worst) rep->worst = a;
            return;
        }
    if (rep->nhits < KAI_MAX_HITS) {
        kai_strlcpy(rep->hits[rep->nhits].rule, rule,
                    sizeof rep->hits[rep->nhits].rule);
        rep->hits[rep->nhits].action = a;
        rep->hits[rep->nhits].count = 1;
        rep->nhits++;
    }
    if (a > rep->worst) rep->worst = a;
}

/* Apply one rule across the whole text, writing cleaned output to out.
 * Returns via in-place rebuild. Used iteratively so later rules see the
 * output of earlier ones. */
static char *apply_rule(const kai_rule *r, char *text, kai_report *rep) {
    regmatch_t m;
    sb_t out;
    sb_init(&out);
    const char *s = text;
    int guard = 0;
    while (*s && guard < 100000) {
        if (regexec(&r->re, s, 1, &m, (s == text) ? 0 : REG_NOTBOL) != 0) break;
        if (m.rm_so < 0) break;
        /* copy the part before the match */
        sb_add(&out, s, (size_t)m.rm_so);
        size_t mlen = (size_t)(m.rm_eo - m.rm_so);
        if (mlen == 0) { /* avoid infinite loop on empty match */
            if (s[m.rm_eo]) sb_add(&out, s + m.rm_eo, 1);
            s += m.rm_eo + (s[m.rm_eo] ? 1 : 0);
            continue;
        }
        if (r->validate && !r->validate(s + m.rm_so, mlen)) {
            sb_add(&out, s + m.rm_so, mlen); /* not a real finding: keep the text */
            s += m.rm_eo;
            continue;
        }
        record(rep, r->name, r->action);
        switch (r->action) {
        case KAI_ACT_REDACT: {
            const char *label = r->name;
            if (strncmp(label, "secret:", 7) == 0) label += 7;
            sb_addf(&out, "[REDACTED by Kai: %s]", label);
            break;
        }
        case KAI_ACT_REPLACE:
            sb_adds(&out, r->replacement ? r->replacement : "");
            break;
        case KAI_ACT_BLOCK:
        case KAI_ACT_WARN:
        case KAI_ACT_NONE:
        default:
            /* leave the matched text in place; block is handled by caller */
            sb_add(&out, s + m.rm_so, mlen);
            break;
        }
        s += m.rm_eo;
        guard++;
    }
    sb_adds(&out, s);
    char *result = sb_take(&out);
    free(text);
    return result;
}

char *kai_scan_text(const kai_policy *p, const char *text, kai_report *rep) {
    if (rep) memset(rep, 0, sizeof *rep);
    if (!p || !text) return strdup(text ? text : "");
    if (strlen(text) > p->max_scan) {
        if (rep) rep->skipped = 1;
        return strdup(text);
    }
    char *cur = strdup(text);
    if (!cur) return NULL;
    for (int i = 0; i < p->nrules && cur; i++)
        cur = apply_rule(&p->rules[i], cur, rep);
    return cur;
}

/* ---- secret plausibility ---- */

/* A random-looking value after a key name is a secret; prose ("the secret
 * itself"), markdown ("secret detectors**") and placeholders ("<your
 * password>", "EXAMPLE_KEY") are not. Look at the value after the key and
 * separator: it must be long enough, varied enough (Shannon entropy), mix
 * character kinds, and not be a known placeholder. (Examples live in
 * tests/run_tests.c, which the self-scan skips.) */
int kai_plausible_secret_value(const char *match, size_t len) {
    /* skip the key name, then the separator run ("= : ' \"") */
    size_t i = 0;
    while (i < len && (isalnum((unsigned char)match[i]) || match[i] == '_' || match[i] == '-')) i++;
    while (i < len && strchr("\"'= :", match[i])) i++;
    const char *v = match + i;
    size_t n = len - i;
    while (n && strchr(".,;:!?)]}*_`", v[n - 1])) n--; /* sentence / markdown punctuation */
    if (n < 8) return 0;
    /* a plain lowercase word ("detectors", "itself") is prose, not a key */
    int word = 1;
    for (size_t k = 0; k < n && word; k++) word = islower((unsigned char)v[k]) || v[k] == '-';
    if (word) return 0;

    char low[128];
    size_t ln = n < sizeof low - 1 ? n : sizeof low - 1;
    for (size_t k = 0; k < ln; k++) low[k] = (char)tolower((unsigned char)v[k]);
    low[ln] = '\0';
    static const char *const PLACEHOLDERS[] = {"example", "changeme", "password", "secret", "your",
                                               "xxxx", "****", "<", ">", "${", "{{", "%s", "redacted",
                                               "dummy", "placeholder", "sample", "todo", "none", "null"};
    for (size_t k = 0; k < sizeof PLACEHOLDERS / sizeof PLACEHOLDERS[0]; k++)
        if (strstr(low, PLACEHOLDERS[k])) return 0;

    int counts[256] = {0}, lower = 0, upper = 0, digit = 0, other = 0;
    for (size_t k = 0; k < n; k++) {
        unsigned char c = (unsigned char)v[k];
        counts[c]++;
        if (islower(c)) lower = 1;
        else if (isupper(c)) upper = 1;
        else if (isdigit(c)) digit = 1;
        else other = 1;
    }
    double h = 0;
    for (int c = 0; c < 256; c++)
        if (counts[c]) {
            double pr = (double)counts[c] / (double)n;
            h -= pr * log2(pr);
        }
    int kinds = lower + upper + digit + other;
    return (h >= 3.0 && kinds >= 2) || kinds >= 3;
}

/* A value given for an explicit password field is a credential however weak
 * it is (all digits included); only placeholders and plain words such as
 * "required" or "unknown" are let through. Examples: tests/run_tests.c. */
int kai_plausible_password_value(const char *match, size_t len) {
    size_t i = 0;
    while (i < len && isalpha((unsigned char)match[i])) i++;
    while (i < len && strchr("\"'= :", match[i])) i++;
    const char *v = match + i;
    size_t n = len - i;
    while (n && strchr(".,;:!?)]}*_`", v[n - 1])) n--;
    if (n < 6) return 0;
    char low[128];
    size_t ln = n < sizeof low - 1 ? n : sizeof low - 1;
    for (size_t k = 0; k < ln; k++) low[k] = (char)tolower((unsigned char)v[k]);
    low[ln] = '\0';
    static const char *const PLACEHOLDERS[] = {"<", ">", "${", "{{", "%s", "xxxx", "****", "....",
                                               "example", "changeme", "placeholder", "redacted", "your"};
    for (size_t k = 0; k < sizeof PLACEHOLDERS / sizeof PLACEHOLDERS[0]; k++)
        if (strstr(low, PLACEHOLDERS[k])) return 0;
    int word = 1;
    for (size_t k = 0; k < n && word; k++) word = islower((unsigned char)v[k]) || v[k] == '-';
    return !word;
}

/* ---- path matching ---- */

/* fnmatch-like, '*' matches within a path segment only (no '/'). */
static int seg_match(const char *pat, const char *str) {
    while (*pat) {
        if (*pat == '*') {
            pat++;
            if (!*pat) { return strchr(str, '/') == NULL; }
            for (; *str && *str != '/'; str++)
                if (seg_match(pat, str)) return 1;
            return seg_match(pat, str);
        }
        if (*str == '\0' || *pat != *str) return 0;
        pat++; str++;
    }
    return *str == '\0';
}

/* Does normalized path np match protect-pattern pat?
 * - pattern with '/': match as absolute prefix (dir) or exact.
 * - bare pattern (e.g. ".env", "*.pem"): match the basename of any segment. */
static int path_matches(const char *pat, const char *np) {
    if (strchr(pat, '/')) {
        size_t pl = strlen(pat);
        if (strncmp(np, pat, pl) == 0 && (np[pl] == '\0' || np[pl] == '/'))
            return 1;
        /* also allow glob on the full path */
        return seg_match(pat, np);
    }
    /* bare: test every path segment's basename */
    const char *seg = np;
    while (seg) {
        const char *next = strchr(seg + 1, '/');
        const char *start = (*seg == '/') ? seg + 1 : seg;
        size_t len = next ? (size_t)(next - start) : strlen(start);
        char tmp[512];
        if (len < sizeof tmp) {
            memcpy(tmp, start, len);
            tmp[len] = '\0';
            if (seg_match(pat, tmp)) return 1;
        }
        seg = next;
    }
    return 0;
}

/* Files that switch Kai (or an agent's hooks) on and off. Always protected,
 * whatever the policy says, so a hijacked agent can't edit its way out:
 * matched by path suffix, so project-level copies are covered too. */
static const char *const AGENT_CONTROL[] = {
    "/.claude/settings.json",
    "/.claude/settings.local.json",
    "/.cursor/hooks.json",
    "/.codex/hooks.json",
    "/.codex/config.toml",
    "/NativeMessagingHosts/io.github.sameehj.kai.json",
};

static int agent_control_path(const char *np, char *why, size_t whylen) {
    size_t n = strlen(np);
    for (size_t i = 0; i < sizeof AGENT_CONTROL / sizeof AGENT_CONTROL[0]; i++) {
        size_t l = strlen(AGENT_CONTROL[i]);
        if (n >= l && strcmp(np + n - l, AGENT_CONTROL[i]) == 0) {
            if (why) kai_strlcpy(why, AGENT_CONTROL[i] + 1, whylen);
            return 1;
        }
    }
    /* Kai's own home (policy, audit log, browser extension) and a custom
     * CODEX_HOME's hooks */
    const char *roots[] = {kai_home(), getenv("CODEX_HOME")};
    for (size_t i = 0; i < sizeof roots / sizeof roots[0]; i++) {
        if (!roots[i] || !*roots[i]) continue;
        char *r = kai_normalize_path(roots[i], NULL);
        size_t rl = r ? strlen(r) : 0;
        int hit = r && strncmp(np, r, rl) == 0 && (np[rl] == '\0' || np[rl] == '/') &&
                  (i == 0 || strstr(np + rl, "hooks.json") || strstr(np + rl, "config.toml"));
        if (hit && why) kai_strlcpy(why, i == 0 ? "~/.kai" : np, whylen);
        free(r);
        if (hit) return 1;
    }
    return 0;
}

int kai_path_protected(const kai_policy *p, const char *path, const char *cwd,
                       char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !path) return 0;
    char *np = kai_normalize_path(path, cwd);
    if (!np) return 0;
    if (agent_control_path(np, why, whylen)) { free(np); return 1; }
    for (int i = 0; i < p->nallow; i++) {
        char *ap = kai_normalize_path(p->allow[i], cwd);
        int hit = ap && (path_matches(p->allow[i], np) || strcmp(ap, np) == 0);
        free(ap);
        if (hit) { free(np); return 0; }
    }
    for (int i = 0; i < p->nprotect; i++) {
        if (path_matches(p->protect[i], np)) {
            if (why) kai_strlcpy(why, p->protect[i], whylen);
            free(np);
            return 1;
        }
    }
    free(np);
    return 0;
}

/* crude shell tokenizer: split on whitespace, strip simple quotes */
/* ---- protected paths in shell commands ---- */

typedef struct {
    const kai_policy *p;
    const char *cwd;
    char *why;
    size_t whylen;
    int hit;
} path_scan_t;

static int path_char(char c) {
    return isalnum((unsigned char)c) || strchr("._/~+@%-", c);
}

/* Check one string: the whole thing as a path, then every path-looking run
 * inside it (so open('/Users/u/.ssh/id_rsa') or --key=~/.aws/creds count). */
static void scan_string(path_scan_t *ps, const char *w) {
    if (ps->hit || !w || !*w) return;
    if (w[0] != '-' && (strchr(w, '/') || w[0] == '~' || strchr(w, '.')) &&
        kai_path_protected(ps->p, w, ps->cwd, ps->why, ps->whylen)) {
        ps->hit = 1;
        return;
    }
    for (const char *c = w; *c && !ps->hit; c++) {
        if (!(*c == '/' || *c == '~' || *c == '.') || (c > w && path_char(c[-1]))) continue;
        const char *e = c;
        while (*e && path_char(*e)) e++;
        size_t n = (size_t)(e - c);
        if (n < 2 || n > 1000 || (c == w && *e == '\0')) { c = e - 1; continue; }
        char tmp[1024];
        memcpy(tmp, c, n);
        tmp[n] = '\0';
        if ((strchr(tmp, '/') || tmp[0] == '.') &&
            kai_path_protected(ps->p, tmp, ps->cwd, ps->why, ps->whylen))
            ps->hit = 1;
        c = e - 1;
    }
}

static void scan_cmd_words(char **argv, int argc, void *ud) {
    for (int i = 0; i < argc; i++) scan_string(ud, argv[i]);
}

static void scan_text_paths(const char *text, void *ud) {
    /* heredoc bodies (python, cat > file, ...): look for paths line by line */
    const char *s = text;
    while (*s && !((path_scan_t *)ud)->hit) {
        const char *e = strchr(s, '\n');
        size_t n = e ? (size_t)(e - s) : strlen(s);
        char *line = malloc(n + 1);
        if (!line) return;
        memcpy(line, s, n);
        line[n] = '\0';
        scan_string(ud, line);
        free(line);
        s = e ? e + 1 : s + n;
    }
}

int kai_command_touches_protected(const kai_policy *p, const char *cmd,
                                   const char *cwd, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !cmd) return 0;
    path_scan_t ps = {p, cwd, why, whylen, 0};
    kai_shell_walk(cmd, scan_cmd_words, scan_text_paths, &ps);
    return ps.hit;
}

int kai_command_looks_like_upload(const kai_policy *p, const char *cmd,
                                   char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !cmd) return 0;
    regmatch_t m;
    for (int i = 0; i < p->nupl; i++) {
        if (regexec(&p->upl[i].re, cmd, 1, &m, 0) == 0) {
            if (why) kai_strlcpy(why, p->upl[i].name, whylen);
            return 1;
        }
    }
    return 0;
}

/* ---- prompt-injection assessment ---- */

/* Blank out (with spaces, keeping newlines and offsets) everything that is
 * an example rather than speech: fenced code, inline code, short quoted
 * strings, and config/comment lines (Kai's own policy, shell comments). */
static void mask_non_prose(char *s) {
    size_t n = strlen(s);
    /* fenced code blocks */
    for (size_t i = 0; i + 2 < n; i++) {
        if ((s[i] == '`' || s[i] == '~') && s[i + 1] == s[i] && s[i + 2] == s[i]) {
            char fence = s[i];
            size_t j = i + 3;
            while (j + 2 < n && !(s[j] == fence && s[j + 1] == fence && s[j + 2] == fence)) j++;
            size_t end = j + 2 < n ? j + 3 : n;
            for (size_t k = i; k < end; k++)
                if (s[k] != '\n') s[k] = ' ';
            i = end;
        }
    }
    /* line by line: config lines, inline code, quoted strings */
    for (char *line = s; line && *line;) {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        const char *t = line;
        while (t < line + len && (*t == ' ' || *t == '\t')) t++;
        static const char *const CONFIG[] = {"rule_injection", "rule_upload", "rule ", "term ",
                                             "#", "//", "/*", "* "};
        int config = 0;
        for (size_t c = 0; c < sizeof CONFIG / sizeof CONFIG[0]; c++)
            if (strncmp(t, CONFIG[c], strlen(CONFIG[c])) == 0) config = 1;
        if (config) {
            memset(line, ' ', len);
        } else {
            /* pass 0: inline code; 1: escaped \"…\" (JSON inside a string);
             * 2: plain "…", skipping escaped quotes so the pairs line up */
            for (int pass = 0; pass < 3; pass++) {
                char *open = NULL;
                for (char *c = line; c < line + len; c++) {
                    int esc = c > line && c[-1] == '\\';
                    int hit = pass == 0 ? *c == '`' : (*c == '"' && (pass == 1 ? esc : !esc));
                    if (!hit) continue;
                    if (!open) { open = c; continue; }
                    if (c - open <= 300)
                        for (char *k = open + 1; k < c; k++)
                            if (!(pass == 2 && *k == '"')) *k = ' ';
                    open = NULL;
                }
            }
        }
        line = nl ? nl + 1 : NULL;
    }
}

/* Invisible characters used to hide text from people but not from models:
 * zero-width spaces/joiners, word joiner, BOM, Unicode tag characters. */
static int has_invisible(const char *s) {
    for (const unsigned char *c = (const unsigned char *)s; *c; c++) {
        if (c[0] == 0xE2 && c[1] == 0x80 && c[2] >= 0x8B && c[2] <= 0x8F) return 1;
        if (c[0] == 0xE2 && c[1] == 0x81 && c[2] == 0xA0) return 1;
        if (c[0] == 0xEF && c[1] == 0xBB && c[2] == 0xBF) return 1;
        if (c[0] == 0xF3 && c[1] == 0xA0 && (c[2] == 0x80 || c[2] == 0x81)) return 1;
    }
    return 0;
}

/* How specific each built-in pattern is. Others default to 2. */
static int rule_weight(const char *name) {
    if (strcmp(name, "ignore_prev") == 0 || strcmp(name, "override_role") == 0) return 3;
    return 2;
}

static int near_word(const char *text, size_t from, size_t to, const char *word) {
    size_t wl = strlen(word);
    for (size_t i = from; i + wl <= to; i++) {
        if (strncasecmp(text + i, word, wl) != 0) continue;
        int before = i == 0 || !isalnum((unsigned char)text[i - 1]);
        int after = !isalnum((unsigned char)text[i + wl]);
        if (before && after) return 1;
    }
    return 0;
}

/* name used to call on someone: "Assistant:", "Claude, …", "AI agents reading this" */
static int greets(const char *text, size_t from, size_t to, const char *name) {
    size_t wl = strlen(name);
    for (size_t i = from; i + wl <= to; i++) {
        if (strncasecmp(text + i, name, wl) != 0) continue;
        if (i > 0 && isalnum((unsigned char)text[i - 1])) continue;
        const char *after = text + i + wl;
        if (isalnum((unsigned char)*after)) continue;
        while (*after == ' ') after++;
        if (*after == ':' || *after == ',') return 1;
        if (strncasecmp(after, "reading this", 12) == 0) return 1;
    }
    return 0;
}

int kai_injection_assess(const kai_policy *p, const char *text, kai_injection_finding *f) {
    memset(f, 0, sizeof *f);
    if (!p || !p->injection_on || !text) return 0;
    size_t n = strlen(text);
    if (n > p->max_scan) return 0;
    char *prose = strdup(text);
    if (!prose) return 0;
    mask_non_prose(prose);
    /* Text in files is wrapped: let a phrase continue across a line break.
     * (Offsets don't move, so matches still point into the original.) */
    for (char *c = prose; *c; c++)
        if (*c == '\n' || *c == '\r') *c = ' ';

    /* names an attacker uses to call on the agent ("Assistant:", "AI agents
     * reading this", "Claude,"); a plain third-person mention doesn't count */
    static const char *const NAMES[] = {"assistant", "ai", "ai agent", "ai agents", "agent", "agents",
                                        "claude", "chatgpt", "codex", "gpt", "llm", "model", "ai model"};
    int best_w = 0, imperative = 0, addressed = 0;
    size_t best_so = 0, best_eo = 0;
    regmatch_t m;
    for (int i = 0; i < p->ninj; i++) {
        if (regexec(&p->inj[i].re, prose, 1, &m, 0) != 0) continue;
        size_t so = (size_t)m.rm_so, eo = (size_t)m.rm_eo;
        int w = rule_weight(p->inj[i].name);
        /* asking to move a key file is more specific than "send a token" */
        if (strcmp(p->inj[i].name, "exfil_ask") == 0) {
            char tmp[256];
            size_t ml = eo - so < sizeof tmp - 1 ? eo - so : sizeof tmp - 1;
            memcpy(tmp, text + so, ml);
            tmp[ml] = '\0';
            if (strstr(tmp, ".ssh") || strstr(tmp, ".env") || strstr(tmp, "id_rsa")) w = 3;
        }
        f->rules++;
        f->score += w;
        if (w > best_w) {
            best_w = w;
            best_so = so;
            best_eo = eo;
            kai_strlcpy(f->rule, p->inj[i].name, sizeof f->rule);
        }
        /* phrased as a command: the match opens its sentence (allowing a
         * short lead-in such as "Please" or "IMPORTANT:") */
        size_t st = so;
        while (st > 0 && !strchr(".!?:\n", text[st - 1])) st--;
        while (st < so && strchr(" \t-*>#", text[st])) st++;
        if (so - st <= 12) imperative = 1;
        if (so >= 7 && strncasecmp(text + so - 7, "please ", 7) == 0) imperative = 1;
        size_t from = so > 150 ? so - 150 : 0, to = eo + 150 < n ? eo + 150 : n;
        /* addressed to the agent: second person, or a name used as a greeting */
        addressed |= near_word(text, from, to, "you") || near_word(text, from, to, "your");
        for (size_t a = 0; a < sizeof NAMES / sizeof NAMES[0] && !addressed; a++)
            addressed = greets(text, from, to, NAMES[a]);
        /* inside an HTML comment: shown to models, hidden from readers */
        const char *open = NULL;
        for (const char *c = strstr(text, "<!--"); c && (size_t)(c - text) < so; c = strstr(c + 4, "<!--"))
            open = c;
        if (open) {
            const char *close = strstr(open, "-->");
            if (!close || (size_t)(close - text) > so) f->hidden = 1;
        }
    }
    free(prose);
    if (f->rules == 0) return 0;
    if (has_invisible(text)) f->hidden = 1;
    f->score += imperative + addressed + (f->hidden ? 2 : 0);

    /* excerpt around the strongest match, on UTF-8 boundaries, redacted */
    size_t a = best_so > 80 ? best_so - 80 : 0, b = best_eo + 80 < n ? best_eo + 80 : n;
    while (a > 0 && ((unsigned char)text[a] & 0xC0) == 0x80) a--;
    while (b < n && ((unsigned char)text[b] & 0xC0) == 0x80) b++;
    char *raw = malloc(b - a + 1);
    if (raw) {
        memcpy(raw, text + a, b - a);
        raw[b - a] = '\0';
        for (char *c = raw; *c; c++)
            if (*c == '\n' || *c == '\r' || *c == '\t') *c = ' ';
        char *clean = kai_scan_text(p, raw, NULL);
        snprintf(f->snippet, sizeof f->snippet, "%s%s%s", a > 0 ? "…" : "", clean ? clean : "",
                 b < n ? "…" : "");
        free(clean);
        free(raw);
        /* snprintf may have cut a multi-byte character: drop the partial one,
         * since agents parse the warning as JSON and reject invalid UTF-8 */
        size_t L = strlen(f->snippet), k = L;
        while (k > 0 && ((unsigned char)f->snippet[k - 1] & 0xC0) == 0x80) k--;
        if (k > 0) {
            unsigned char lead = (unsigned char)f->snippet[k - 1];
            size_t need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
            if (L - (k - 1) < need) f->snippet[k - 1] = '\0';
        }
    }
    return f->score;
}

int kai_injection_check(const kai_policy *p, const char *text, char *which,
                        size_t whichlen) {
    if (which && whichlen) which[0] = '\0';
    kai_injection_finding f;
    if (kai_injection_assess(p, text, &f) < KAI_INJECTION_WARN) return 0;
    if (which) kai_strlcpy(which, f.rule, whichlen);
    return f.rules;
}

void kai_report_summary(const kai_report *rep, char *out, size_t outlen) {
    if (!outlen) return;
    out[0] = '\0';
    if (!rep || rep->nhits == 0) { kai_strlcpy(out, "no findings", outlen); return; }
    sb_t b;
    sb_init(&b);
    for (int i = 0; i < rep->nhits; i++) {
        if (i) sb_adds(&b, ", ");
        sb_addf(&b, "%s x%d (%s)", rep->hits[i].rule, rep->hits[i].count,
                kai_action_name(rep->hits[i].action));
    }
    char *s = sb_take(&b);
    kai_strlcpy(out, s, outlen);
    free(s);
}
