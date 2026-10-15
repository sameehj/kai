/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

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

int kai_path_protected(const kai_policy *p, const char *path, const char *cwd,
                       char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !path) return 0;
    char *np = kai_normalize_path(path, cwd);
    if (!np) return 0;
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
int kai_command_touches_protected(const kai_policy *p, const char *cmd,
                                   const char *cwd, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p) return 0;
    char *copy = strdup(cmd ? cmd : "");
    if (!copy) return 0;
    int hit = 0;
    char *save = NULL;
    for (char *tok = strtok_r(copy, " \t\n|;&><()", &save);
         tok && !hit; tok = strtok_r(NULL, " \t\n|;&><()", &save)) {
        /* strip surrounding quotes */
        size_t tl = strlen(tok);
        if (tl >= 2 && (tok[0] == '"' || tok[0] == '\'') &&
            tok[tl - 1] == tok[0]) {
            tok[tl - 1] = '\0';
            tok++;
        }
        if (tok[0] == '-' || tok[0] == '\0') continue;
        /* only consider things that look like paths or known names */
        if (strchr(tok, '/') || tok[0] == '~' || strchr(tok, '.')) {
            if (kai_path_protected(p, tok, cwd, why, whylen)) hit = 1;
        }
    }
    free(copy);
    return hit;
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

int kai_injection_check(const kai_policy *p, const char *text, char *which,
                        size_t whichlen) {
    if (which && whichlen) which[0] = '\0';
    if (!p || !p->injection_on || !text) return 0;
    if (strlen(text) > p->max_scan) return 0;
    int count = 0;
    regmatch_t m;
    for (int i = 0; i < p->ninj; i++) {
        if (regexec(&p->inj[i].re, text, 1, &m, 0) == 0) {
            if (count == 0 && which) kai_strlcpy(which, p->inj[i].name, whichlen);
            count++;
        }
    }
    return count;
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
