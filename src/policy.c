/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial */
#include "internal.h"

#include <ctype.h>
#include <errno.h>
#include <fnmatch.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* Upload patterns from earlier default policies, matched against raw command
 * text, and their replacements for the command view (kai_shell_view). A
 * policy file written by an older `kai init` still holds the old ones; they
 * fired on any mention (a heredoc or an argument saying "netcat"). Only an
 * unchanged default is upgraded, never a pattern the user wrote. */
static const struct {
    const char *old, *now;
} UPLOAD_UPGRADES[] = {
    {"(curl|wget).*(-d|--data|-T|--upload-file|-F).*@",
     "(^|\\| )(curl|wget) .*(-d|--data|-T|--upload-file|-F).*@"},
    {"(curl|wget).*\\|.*(sh|bash|zsh|python)",
     "(^|\\| )(curl|wget) .*\\| (sh|bash|zsh|python[0-9.]*)( |$)"},
    {"(^|[^a-z])(nc|ncat|netcat)([^a-z]|$)", "(^|\\| )(nc|ncat|netcat)( |$)"},
    {"(^|[^a-z])scp[^\"]+:", "(^|\\| )scp .*:"},
};

/* The built-in default policy. Kept in sync with policy/default.policy;
 * tests/test_policy checks that the shipped file parses identically. */
static const char DEFAULT_POLICY[] =
    "protect ~/.ssh\n"
    "protect ~/.aws\n"
    "protect ~/.config/gcloud\n"
    "protect ~/.kube\n"
    "protect ~/.docker/config.json\n"
    "protect ~/.netrc\n"
    "protect ~/.npmrc\n"
    "protect ~/.pypirc\n"
    "protect ~/.gnupg\n"
    "protect ~/.kai\n"
    "protect .env\n"
    "protect .env.*\n"
    "protect *.pem\n"
    "protect *.key\n"
    "protect id_rsa\n"
    "protect id_ed25519\n"
    "allow .env.example\n"
    "allow .env.sample\n"
    "secrets redact\n"
    "on_prompt_secret block\n"
    "on_file_secret ask\n"
    "on_upload block\n"
    "injection warn\n"
    "max_scan_bytes 2000000\n"
    "egress log\n"
    "storage off\n"
    "audit_context on\n"
    "rule_upload curl_upload (^|\\| )(curl|wget) .*(-d|--data|-T|--upload-file|-F).*@\n"
    "rule_upload pipe_to_shell (^|\\| )(curl|wget) .*\\| (sh|bash|zsh|python[0-9.]*)( |$)\n"
    "rule_upload netcat (^|\\| )(nc|ncat|netcat)( |$)\n"
    "rule_upload remote_scp (^|\\| )scp .*:\n"
    "rule_injection ignore_prev ignore (all |your |previous |prior )*instructions\n"
    "rule_injection new_instr (new|updated|system) (instructions|directive|prompt)[: ]\n"
    "rule_injection exfil_ask "
    "(send|upload|post|exfiltrate|leak).{0,40}(\\.ssh|\\.env|secret|credential|token|api[_ ]?key)\n"
    "rule_injection override_role you are (now )?(a |an )?(different|new|dan|developer mode)\n"
    "rule_injection disregard "
    "(disregard|forget|override).{0,20}(instruction|rule|guardrail|policy)\n";

/* Built-in secret detectors. name|regex. Applied when `secrets` != off. */
static const struct {
    const char *name, *re;
} BUILTIN_SECRETS[] = {
    /* Patterns avoid \b and \s for POSIX portability (glibc + macOS BSD). */
    {"private_key_block",
     "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"},
    {"aws_access_key", "(AKIA|ASIA)[0-9A-Z]{16}"},
    {"aws_secret_key", "aws_secret_access_key[\"'= :]+[A-Za-z0-9/+]{40}"},
    {"github_token", "(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"},
    {"gitlab_token", "glpat-[A-Za-z0-9_-]{20,}"},
    {"slack_token", "xox[baprs]-[A-Za-z0-9-]{10,}"},
    {"stripe_key", "(sk|rk)_(live|test)_[A-Za-z0-9]{16,}"},
    {"google_api_key", "AIza[0-9A-Za-z_-]{35}"},
    {"openai_key", "sk-(proj-)?[A-Za-z0-9_-]{20,}"},
    {"anthropic_key", "sk-ant-[A-Za-z0-9_-]{20,}"},
    {"openrouter_key", "sk-or-v1-[A-Za-z0-9]{32,}"},
    {"jwt", "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"},
    {"db_url_with_password",
     "(postgres|postgresql|mysql|mongodb)(\\+srv)?://[^ :@/]+:[^ :@/]+@"},
    /* "password: …" / "pw=…": an explicit password field, any real value */
    {"password_assign",
     "(password|passwd|passcode|pwd|pw)[\"']?[ ]*[:=][ \"']*[^ \"']{6,}"},
    /* vaguer key names that also appear in prose: value must look random */
    {"generic_secret_assign",
     "(secret|api[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)[\"'= :]+[^ \"']{8,}"},
};

/* Known agents. Always active; policy `agent` lines add more.
 * kind: exe = executable path glob, arg = any argv element glob,
 *       team = code-signing Team ID (macOS). */
static const struct {
    const char *name, *kind, *pattern;
} BUILTIN_AGENTS[] = {
    {"claude", "arg", "*/@anthropic-ai/claude-code/*"},
    {"claude", "arg", "*/.claude/local/*"},
    {"claude", "exe", "*/.local/share/claude/versions/*"},
    {"claude", "exe", "*/.claude/local/*"},
    {"cursor", "exe", "/Applications/Cursor.app/Contents/*"},
    {"cursor", "team", "VDXQ22DGB9"},
    {"codex", "exe", "*/bin/codex"},
    {"codex", "arg", "*/@openai/codex/*"},
    {"codex", "team", "2DC432GLL2"},
    {"gemini", "arg", "*/@google/gemini-cli/*"},
    /* Added to the catalog (unverified against installed copies -- see
     * AGENT_CATALOG below; patterns are best-effort and may need refining). */
    {"aider", "arg", "*/bin/aider"},
    {"aider", "arg", "*aider_chat*"},
    {"opencode", "arg", "*/opencode/*"},
    {"opencode", "exe", "*/bin/opencode"},
    {"goose", "exe", "*/bin/goose"},
    {"goose", "arg", "*goose*session*"},
    {"antigravity", "exe", "*/Antigravity.app/Contents/*"},
    {"windsurf", "exe", "/Applications/Windsurf.app/Contents/*"},
    {"kiro", "exe", "*/Kiro.app/Contents/*"},
    {"zed", "exe", "*/Zed.app/Contents/*"},
    {"zed", "exe", "*/bin/zed"},
};

/* Agent product catalog: maps a recognized agent name to its KIND (how Kai
 * finds its sessions) and whether Kai has a hook integration for it. `verified`
 * is 1 only for entries checked against an installed copy. Shipped with Kai; a
 * user can add entries through `kai policy add agent` (the "Add agent" button).
 * kind: 0=cli, 1=ide, 2=ide-extension, 3=browser. */
static const struct { const char *name; int kind; int hooks; int verified; } AGENT_CATALOG[] = {
    {"claude", 0, 1, 1}, {"codex", 0, 1, 1}, {"gemini", 0, 0, 1},
    {"cursor", 1, 1, 1}, {"chrome", 3, 1, 1},
    {"aider", 0, 0, 0}, {"opencode", 0, 0, 0}, {"goose", 0, 0, 0},
    {"antigravity", 1, 0, 0}, {"windsurf", 1, 0, 0}, {"kiro", 1, 0, 0}, {"zed", 1, 0, 0},
    /* ide-extension agents run INSIDE the editor's process, so there is no safe
     * static rule that tags them without also tagging (and walling off) the
     * user's own editing. They get NO match rule on purpose: Kai covers only the
     * shells/processes they start, and the agent card discloses this. */
    {"cline", 2, 0, 0}, {"copilot", 2, 0, 0},
};

int kai_agent_product_kind(const char *name) {
    if (name)
        for (size_t i = 0; i < sizeof AGENT_CATALOG / sizeof AGENT_CATALOG[0]; i++)
            if (strcmp(AGENT_CATALOG[i].name, name) == 0) return AGENT_CATALOG[i].kind;
    return KAI_AGENT_CLI;   /* unknown agents behave like a CLI (one root per terminal) */
}
int kai_agent_catalog_verified(const char *name) {
    if (name)
        for (size_t i = 0; i < sizeof AGENT_CATALOG / sizeof AGENT_CATALOG[0]; i++)
            if (strcmp(AGENT_CATALOG[i].name, name) == 0) return AGENT_CATALOG[i].verified;
    return 0;
}
int kai_agent_has_hooks(const char *name) {
    if (name)
        for (size_t i = 0; i < sizeof AGENT_CATALOG / sizeof AGENT_CATALOG[0]; i++)
            if (strcmp(AGENT_CATALOG[i].name, name) == 0) return AGENT_CATALOG[i].hooks;
    return 0;
}

/* ---- MCP tool identity + policy (Step 4) ----
 * An MCP tool call is a (server, tool) pair. Claude Code names them
 * "mcp__<server>__<tool>"; the tool part may itself contain "__". We parse that
 * shape and record anything else as unknown (handled as a normal tool call). */
int kai_mcp_parse_tool(const char *tool_name, char *server, size_t slen,
                       char *tool, size_t tlen) {
    if (server && slen) server[0] = '\0';
    if (tool && tlen) tool[0] = '\0';
    if (!tool_name || strncmp(tool_name, "mcp__", 5) != 0) return 0;
    const char *s = tool_name + 5;
    const char *sep = strstr(s, "__");
    if (!sep || sep == s) return 0;            /* need a non-empty server */
    const char *t = sep + 2;
    if (!*t) return 0;                          /* need a non-empty tool */
    if (server && slen) {
        size_t n = (size_t)(sep - s);
        if (n >= slen) n = slen - 1;
        memcpy(server, s, n); server[n] = '\0';
    }
    if (tool && tlen) kai_strlcpy(tool, t, tlen);
    return 1;
}

/* Decide an MCP (server, tool) call against the policy. Most-specific wins:
 * an exact server+tool rule, then a server+"*" rule. No rule = ask (a decision
 * card), so a newly-seen server never runs silently. */
kai_action kai_mcp_decide(const kai_policy *p, const char *server, const char *tool) {
    if (!p || !server) return KAI_ACT_WARN;
    int best = -1, best_specific = -1;
    for (int i = 0; i < p->nmcp; i++) {
        if (strcmp(p->mcp[i].server, server) != 0 &&
            strcmp(p->mcp[i].server, "*") != 0)
            continue;
        int specific = 0;
        if (strcmp(p->mcp[i].server, server) == 0) specific += 2;
        if (tool && strcmp(p->mcp[i].tool, tool) == 0) specific += 1;
        else if (strcmp(p->mcp[i].tool, "*") != 0) continue; /* tool named but no match */
        if (specific > best_specific) { best_specific = specific; best = i; }
    }
    return best < 0 ? KAI_ACT_WARN : p->mcp[best].action;
}

/* A plain coverage disclosure for the agent card, or NULL when fully covered. */
const char *kai_agent_coverage_note(const char *name) {
    switch (kai_agent_product_kind(name)) {
    case KAI_AGENT_IDE_EXTENSION:
        return "Runs inside your editor — Kai covers only the shells it starts, "
               "not your own editing.";
    case KAI_AGENT_BROWSER:
        return "Browser extension — the network and storage walls don't apply.";
    default:
        return kai_agent_catalog_verified(name) ? NULL
             : "Profile not yet verified against an installed copy.";
    }
}

/* Hosts agents may always reach. Each entry also covers its subdomains.
 * Policy `egress_allow` lines add more. */
static const char *const BUILTIN_EGRESS[] = {
    /* model providers and agent backends */
    "anthropic.com", "claude.ai", "claude.com", "openai.com", "chatgpt.com",
    "openrouter.ai", "googleapis.com", "cursor.sh", "cursor.com",
    "cursorapi.com", "cursor-cdn.com",
    /* source hosting */
    "github.com", "githubusercontent.com", "gitlab.com", "bitbucket.org",
    /* package registries */
    "npmjs.org", "npmjs.com", "yarnpkg.com", "pypi.org", "pythonhosted.org",
    "crates.io", "proxy.golang.org", "sum.golang.org", "rubygems.org",
    "repo.maven.apache.org", "repo1.maven.org", "docker.io", "ghcr.io",
    "brew.sh",
};

static char *trimdup(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    const char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' ||
                       end[-1] == '\n'))
        end--;
    size_t n = (size_t)(end - s);
    char *r = malloc(n + 1);
    if (r) { memcpy(r, s, n); r[n] = '\0'; }
    return r;
}

static kai_action parse_action(const char *tok, char **replacement) {
    *replacement = NULL;
    if (strncmp(tok, "replace:", 8) == 0) {
        const char *v = tok + 8;
        if (*v == '"') {
            v++;
            const char *e = strchr(v, '"');
            size_t n = e ? (size_t)(e - v) : strlen(v);
            char *r = malloc(n + 1);
            if (r) { memcpy(r, v, n); r[n] = '\0'; }
            *replacement = r;
        } else {
            *replacement = strdup(v);
        }
        return KAI_ACT_REPLACE;
    }
    if (strcmp(tok, "block") == 0) return KAI_ACT_BLOCK;
    if (strcmp(tok, "redact") == 0) return KAI_ACT_REDACT;
    if (strcmp(tok, "warn") == 0 || strcmp(tok, "ask") == 0) return KAI_ACT_WARN;
    if (strcmp(tok, "off") == 0 || strcmp(tok, "none") == 0) return KAI_ACT_NONE;
    return KAI_ACT_WARN;
}

/* Turn a glob of exact words (term) into an anchored regex is overkill;
 * we instead match terms literally and case-insensitively in scan.c.
 * Here we only compile real regex rules. */
static int add_rule(kai_rule **arr, int *n, int *cap, const char *name,
                    kai_action act, char *replacement, const char *pattern,
                    int literal, char *err, size_t errlen) {
    if (*n >= *cap) {
        int nc = *cap ? *cap * 2 : 8;
        kai_rule *na = realloc(*arr, (size_t)nc * sizeof **arr);
        if (!na) { free(replacement); return -1; }
        *arr = na;
        *cap = nc;
    }
    kai_rule *r = &(*arr)[*n];
    memset(r, 0, sizeof *r);
    kai_strlcpy(r->name, name, sizeof r->name);
    r->action = act;
    r->replacement = replacement;

    /* For a literal term, quote every regex metacharacter. */
    char *buf = NULL;
    const char *pat = pattern;
    if (literal) {
        sb_t b;
        sb_init(&b);
        for (const char *c = pattern; *c; c++) {
            if (strchr(".^$*+?()[]{}|\\", *c)) sb_add(&b, "\\", 1);
            sb_add(&b, c, 1);
        }
        buf = sb_take(&b);
        pat = buf;
    }
    int rc = regcomp(&r->re, pat, REG_EXTENDED | REG_ICASE | REG_NEWLINE);
    free(buf);
    if (rc != 0) {
        char msg[256];
        regerror(rc, &r->re, msg, sizeof msg);
        snprintf(err, errlen, "bad pattern for rule '%s': %s", name, msg);
        free(replacement);
        r->replacement = NULL;
        return -1;
    }
    r->compiled = 1;
    (*n)++;
    return 0;
}

static int add_list(char **arr, int *n, const char *val) {
    if (*n >= KAI_MAX_LIST) return -1;
    char *d = kai_expand_home(val);
    if (!d) return -1;
    arr[(*n)++] = d;
    return 0;
}

static kai_policy *policy_new(void) {
    kai_policy *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->builtin_secrets = KAI_ACT_REDACT;
    p->prompt_action = KAI_ACT_BLOCK;
    p->file_secret_action = KAI_ACT_BLOCK;
    p->file_secret_ask = 1;
    p->upload_action = KAI_ACT_BLOCK;
    p->injection_on = 1;
    p->max_scan = 2000000;
    p->egress_mode = KAI_EGRESS_LOG;
    p->storage_mode = KAI_STORAGE_OFF; /* needs Apple's entitlement; off until then */
    p->gateway_port = 8787;
    p->audit_context = 1;
    kai_strlcpy(p->source, "built-in", sizeof p->source);
    return p;
}

static int next_tok(char **cur, char **tok) {
    char *s = *cur;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) return 0;
    *tok = s;
    while (*s && *s != ' ' && *s != '\t') s++;
    if (*s) { *s = '\0'; s++; }
    *cur = s;
    return 1;
}

/* Read an action token, honoring replace:"..." which may contain spaces.
 * Leaves *cur pointing just past the action. */
static int next_action_tok(char **cur, char **tok) {
    char *s = *cur;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) return 0;
    *tok = s;
    if (strncmp(s, "replace:\"", 9) == 0) {
        s += 9;
        while (*s && *s != '"') s++;
        if (*s == '"') s++; /* include closing quote */
    } else {
        while (*s && *s != ' ' && *s != '\t') s++;
    }
    if (*s) { *s = '\0'; s++; }
    *cur = s;
    return 1;
}

static kai_policy *parse(const char *text, const char *source, char *err,
                         size_t errlen) {
    if (errlen) err[0] = '\0';
    kai_policy *p = policy_new();
    if (!p) { snprintf(err, errlen, "out of memory"); return NULL; }
    if (source) kai_strlcpy(p->source, source, sizeof p->source);

    char *copy = strdup(text);
    if (!copy) { kai_policy_free(p); snprintf(err, errlen, "out of memory"); return NULL; }

    int lineno = 0, failed = 0;
    char *save = NULL;
    for (char *line = strtok_r(copy, "\n", &save); line && !failed;
         line = strtok_r(NULL, "\n", &save)) {
        lineno++;
        char *cur = line;
        char *d;
        if (!next_tok(&cur, &d)) continue;
        if (d[0] == '#') continue;

        if (strcmp(d, "protect") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            add_list(p->protect, &p->nprotect, v);
        } else if (strcmp(d, "allow") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            add_list(p->allow, &p->nallow, v);
        } else if (strcmp(d, "secrets") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            char *rep; p->builtin_secrets = parse_action(v, &rep); free(rep);
        } else if (strcmp(d, "on_prompt_secret") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            char *rep; p->prompt_action = parse_action(v, &rep); free(rep);
        } else if (strcmp(d, "on_file_secret") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            /* ask: block, but where the agent can ask the user, let them decide */
            p->file_secret_ask = strcmp(v, "ask") == 0;
            char *rep;
            p->file_secret_action = p->file_secret_ask ? KAI_ACT_BLOCK : parse_action(v, &rep);
            if (!p->file_secret_ask) free(rep);
        } else if (strcmp(d, "on_upload") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            p->upload_ask = strcmp(v, "ask") == 0;
            char *rep;
            p->upload_action = p->upload_ask ? KAI_ACT_BLOCK : parse_action(v, &rep);
            if (!p->upload_ask) free(rep);
        } else if (strcmp(d, "injection") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            p->injection_on = strcmp(v, "off") != 0;
        } else if (strcmp(d, "max_scan_bytes") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            long m = strtol(v, NULL, 10);
            if (m > 0) p->max_scan = (size_t)m;
        } else if (strcmp(d, "egress") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            if (strcmp(v, "block") == 0) p->egress_mode = KAI_EGRESS_BLOCK;
            else if (strcmp(v, "off") == 0) p->egress_mode = KAI_EGRESS_OFF;
            else p->egress_mode = KAI_EGRESS_LOG;
        } else if (strcmp(d, "storage") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            if (strcmp(v, "block") == 0) p->storage_mode = KAI_STORAGE_BLOCK;
            else if (strcmp(v, "log") == 0) p->storage_mode = KAI_STORAGE_LOG;
            else p->storage_mode = KAI_STORAGE_OFF;
        } else if (strcmp(d, "egress_allow") == 0) {
            char *v;
            while (next_tok(&cur, &v) && v[0] != '#') {
                if (strncmp(v, "*.", 2) == 0) v += 2;
                if (p->negress < KAI_MAX_LIST) p->egress_allow[p->negress++] = strdup(v);
            }
        } else if (strcmp(d, "agent") == 0) {
            char *nm, *kind, *pat;
            if (!next_tok(&cur, &nm) || !next_tok(&cur, &kind)) continue;
            pat = cur; while (*pat == ' ' || *pat == '\t') pat++;
            char *pt = trimdup(pat);
            if (!pt || !*pt || (strcmp(kind, "exe") && strcmp(kind, "arg") && strcmp(kind, "team")) ||
                p->nagents >= KAI_MAX_LIST) {
                free(pt);
                continue;
            }
            char *ex = kai_expand_home(pt);
            free(pt);
            kai_strlcpy(p->agents[p->nagents].name, nm, sizeof p->agents[0].name);
            kai_strlcpy(p->agents[p->nagents].kind, kind, sizeof p->agents[0].kind);
            p->agents[p->nagents++].pattern = ex;
        } else if (strcmp(d, "mcp") == 0) {
            /* mcp <server> <tool|*> allow|ask|block */
            char *server, *tool, *act;
            if (!next_tok(&cur, &server) || !next_tok(&cur, &tool) ||
                !next_tok(&cur, &act) || p->nmcp >= KAI_MAX_LIST)
                continue;
            kai_action a = strcmp(act, "allow") == 0  ? KAI_ACT_NONE
                           : strcmp(act, "block") == 0 ? KAI_ACT_BLOCK
                                                       : KAI_ACT_WARN; /* ask */
            kai_strlcpy(p->mcp[p->nmcp].server, server, sizeof p->mcp[0].server);
            kai_strlcpy(p->mcp[p->nmcp].tool, tool, sizeof p->mcp[0].tool);
            p->mcp[p->nmcp++].action = a;
        } else if (strcmp(d, "gateway_port") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            long port = strtol(v, NULL, 10);
            if (port > 0 && port < 65536) p->gateway_port = (int)port;
        } else if (strcmp(d, "term") == 0) {
            char *act, *txt;
            if (!next_action_tok(&cur, &act)) continue;
            txt = cur; while (*txt == ' ' || *txt == '\t') txt++;
            char *t = trimdup(txt);
            if (!t || !*t) { free(t); continue; }
            char *rep; kai_action a = parse_action(act, &rep);
            char nm[KAI_NAME_MAX]; snprintf(nm, sizeof nm, "term:%.48s", t);
            if (add_rule(&p->rules, &p->nrules, &p->caprules, nm, a, rep, t, 1,
                         err, errlen) != 0) failed = 1;
            free(t);
        } else if (strcmp(d, "rule") == 0) {
            char *nm, *act, *pat;
            if (!next_tok(&cur, &nm) || !next_action_tok(&cur, &act)) continue;
            pat = cur; while (*pat == ' ' || *pat == '\t') pat++;
            char *pt = trimdup(pat);
            if (!pt || !*pt) { free(pt); continue; }
            char *rep; kai_action a = parse_action(act, &rep);
            if (add_rule(&p->rules, &p->nrules, &p->caprules, nm, a, rep, pt, 0,
                         err, errlen) != 0) failed = 1;
            free(pt);
        } else if (strcmp(d, "rule_injection") == 0) {
            char *nm, *pat;
            if (!next_tok(&cur, &nm)) continue;
            pat = cur; while (*pat == ' ' || *pat == '\t') pat++;
            char *pt = trimdup(pat);
            if (!pt || !*pt) { free(pt); continue; }
            if (add_rule(&p->inj, &p->ninj, &p->capinj, nm, KAI_ACT_WARN, NULL,
                         pt, 0, err, errlen) != 0) failed = 1;
            free(pt);
        } else if (strcmp(d, "rule_upload") == 0) {
            char *nm, *pat;
            if (!next_tok(&cur, &nm)) continue;
            pat = cur; while (*pat == ' ' || *pat == '\t') pat++;
            char *pt = trimdup(pat);
            if (!pt || !*pt) { free(pt); continue; }
            const char *use = pt;
            for (size_t u = 0; u < sizeof UPLOAD_UPGRADES / sizeof UPLOAD_UPGRADES[0]; u++)
                if (strcmp(pt, UPLOAD_UPGRADES[u].old) == 0) use = UPLOAD_UPGRADES[u].now;
            if (add_rule(&p->upl, &p->nupl, &p->capupl, nm, KAI_ACT_BLOCK, NULL,
                         use, 0, err, errlen) != 0) failed = 1;
            free(pt);
        } else if (strcmp(d, "exempt") == 0) {
            /* exempt <rule> <glob over the command>: the user's own exception */
            char *nm, *pat;
            if (!next_tok(&cur, &nm) || p->nexempt >= KAI_MAX_LIST) continue;
            pat = cur; while (*pat == ' ' || *pat == '\t') pat++;
            char *pt = trimdup(pat);
            if (!pt || !*pt || kai_rule_is_builtin(nm)) { free(pt); continue; }
            kai_strlcpy(p->exempt[p->nexempt].rule, nm, sizeof p->exempt[0].rule);
            p->exempt[p->nexempt++].pattern = pt;
        } else if (strcmp(d, "audit_context") == 0) {
            char *v; if (!next_tok(&cur, &v)) continue;
            p->audit_context = strcmp(v, "off") != 0;
        } else {
            /* unknown directive: ignore, forward-compatible */
        }
    }
    free(copy);

    if (failed) {
        if (errlen && err[0] == '\0')
            snprintf(err, errlen, "policy error near line %d", lineno);
        kai_policy_free(p);
        return NULL;
    }

    /* Built-in agents and egress hosts come after the user's own entries. */
    for (size_t i = 0; i < sizeof BUILTIN_AGENTS / sizeof BUILTIN_AGENTS[0] &&
                       p->nagents < KAI_MAX_LIST; i++) {
        kai_strlcpy(p->agents[p->nagents].name, BUILTIN_AGENTS[i].name, sizeof p->agents[0].name);
        kai_strlcpy(p->agents[p->nagents].kind, BUILTIN_AGENTS[i].kind, sizeof p->agents[0].kind);
        p->agents[p->nagents++].pattern = strdup(BUILTIN_AGENTS[i].pattern);
    }
    for (size_t i = 0; i < sizeof BUILTIN_EGRESS / sizeof BUILTIN_EGRESS[0] &&
                       p->negress < KAI_MAX_LIST; i++)
        p->egress_allow[p->negress++] = strdup(BUILTIN_EGRESS[i]);

    /* Compile built-in secret detectors unless turned off. */
    if (p->builtin_secrets != KAI_ACT_NONE) {
        int n = (int)(sizeof BUILTIN_SECRETS / sizeof BUILTIN_SECRETS[0]);
        for (int i = 0; i < n; i++) {
            char nm[KAI_NAME_MAX];
            snprintf(nm, sizeof nm, "secret:%s", BUILTIN_SECRETS[i].name);
            if (add_rule(&p->rules, &p->nrules, &p->caprules, nm,
                         p->builtin_secrets, NULL, BUILTIN_SECRETS[i].re, 0,
                         err, errlen) != 0) {
                kai_policy_free(p);
                return NULL;
            }
            /* the generic pattern only matters when the value looks like a secret */
            if (strcmp(BUILTIN_SECRETS[i].name, "generic_secret_assign") == 0)
                p->rules[p->nrules - 1].validate = kai_plausible_secret_value;
            if (strcmp(BUILTIN_SECRETS[i].name, "password_assign") == 0)
                p->rules[p->nrules - 1].validate = kai_plausible_password_value;
        }
    }
    return p;
}

const char *kai_default_policy(void) { return DEFAULT_POLICY; }

/* $KAI_POLICY, else <kai home>/policy. */
const char *kai_policy_file(void) {
    static char buf[1200];
    if (buf[0]) return buf;
    const char *env = getenv("KAI_POLICY");
    if (env && *env) kai_strlcpy(buf, env, sizeof buf);
    else snprintf(buf, sizeof buf, "%s/policy", kai_home());
    return buf;
}

/* Path prefix test that resists "/.kai/../" and trailing-slash tricks only at
 * the textual level; the storage wall already receives canonicalized ES paths,
 * and the CLI uses this on realpath'd inputs. A match means the path IS `dir`
 * or lies directly beneath it. */
static int under_dir(const char *path, const char *dir) {
    size_t dl = strlen(dir);
    if (dl == 0) return 0;
    if (strncmp(path, dir, dl) != 0) return 0;
    return path[dl] == '\0' || path[dl] == '/';
}

int kai_path_is_control_store(const char *path) {
    if (!path || !*path) return 0;
    if (strcmp(path, kai_policy_file()) == 0) return 1;
    char dir[1300];
    snprintf(dir, sizeof dir, "%s/grants", kai_home());
    if (under_dir(path, dir)) return 1;
    snprintf(dir, sizeof dir, "%s/pending-policy", kai_home());
    if (under_dir(path, dir)) return 1;
    snprintf(dir, sizeof dir, "%s/registry", kai_home());   /* session registry (S1) */
    if (under_dir(path, dir)) return 1;
    return 0;
}

kai_policy *kai_policy_from_string(const char *text, char *err, size_t errlen) {
    return parse(text, "string", err, errlen);
}

kai_policy *kai_policy_load(const char *path, char *err, size_t errlen) {
    char *chosen = NULL;
    if (path && *path) {
        chosen = strdup(path);
    } else {
        const char *def = kai_policy_file();
        /* Distinguish "no policy file" (use built-in defaults) from "file is
         * there but we can't read it" (an error — never silently run on
         * defaults when the user has a policy). The storage wall denies
         * unsigned processes from reading ~/.kai, which is how this happens. */
        struct stat st;
        if (stat(def, &st) == 0) chosen = strdup(def);
        else if (errno != ENOENT) {
            if (err && errlen) snprintf(err, errlen, "cannot access policy file: %s (%s)", def, strerror(errno));
            return NULL;
        }
    }
    if (!chosen) return parse(DEFAULT_POLICY, "built-in", err, errlen);

    size_t len = 0;
    char *txt = kai_read_file(chosen, 4000000, &len);
    if (!txt) {
        if (err && errlen)
            snprintf(err, errlen, "policy file exists but can't be read: %s (%s)", chosen, strerror(errno));
        free(chosen);
        return NULL;
    }
    kai_policy *p = parse(txt, chosen, err, errlen);
    free(txt);
    free(chosen);
    return p;
}

void kai_policy_free(kai_policy *p) {
    if (!p) return;
    for (int i = 0; i < p->nrules; i++) {
        if (p->rules[i].compiled) regfree(&p->rules[i].re);
        free(p->rules[i].replacement);
    }
    for (int i = 0; i < p->ninj; i++)
        if (p->inj[i].compiled) regfree(&p->inj[i].re);
    for (int i = 0; i < p->nupl; i++)
        if (p->upl[i].compiled) regfree(&p->upl[i].re);
    free(p->rules); free(p->inj); free(p->upl);
    for (int i = 0; i < p->nprotect; i++) free(p->protect[i]);
    for (int i = 0; i < p->nallow; i++) free(p->allow[i]);
    for (int i = 0; i < p->negress; i++) free(p->egress_allow[i]);
    for (int i = 0; i < p->nagents; i++) free(p->agents[i].pattern);
    for (int i = 0; i < p->nexempt; i++) free(p->exempt[i].pattern);
    free(p);
}

const char *kai_policy_source(const kai_policy *p) {
    return p ? p->source : "built-in";
}
kai_action kai_policy_prompt_action(const kai_policy *p) { return p->prompt_action; }
kai_action kai_policy_file_secret_action(const kai_policy *p) { return p->file_secret_action; }
kai_action kai_policy_upload_action(const kai_policy *p) { return p->upload_action; }
int kai_policy_file_secret_ask(const kai_policy *p) { return p ? p->file_secret_ask : 0; }
int kai_policy_upload_ask(const kai_policy *p) { return p ? p->upload_ask : 0; }
int kai_policy_audit_context(const kai_policy *p) { return p && p->audit_context; }

/* '*' and '?' span anything, '/' and newlines included: the pattern is over
 * the whole command, usually the exact command with a few wildcards. */
int kai_policy_exempt(const kai_policy *p, const char *rule, const char *target) {
    if (!p || !rule || !target || kai_rule_is_builtin(rule)) return 0;
    for (int i = 0; i < p->nexempt; i++)
        if (strcmp(p->exempt[i].rule, rule) == 0 && fnmatch(p->exempt[i].pattern, target, 0) == 0)
            return 1;
    return 0;
}
kai_egress_mode kai_policy_egress_mode(const kai_policy *p) {
    return p ? p->egress_mode : KAI_EGRESS_OFF;
}

kai_storage_mode kai_policy_storage_mode(const kai_policy *p) {
    return p ? p->storage_mode : KAI_STORAGE_OFF;
}
