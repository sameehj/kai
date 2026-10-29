/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * `kai status` and `kai doctor` (Release Plan v2.1, A2): measured state only.
 *
 * Every "active", "protecting" or "healthy" here comes from a check run now:
 * the agent's own hook command answering a synthetic request, the last time
 * the agent really called Kai (audit log), the walls' verified heartbeats, the
 * audit chain. A hook that is installed but never called (Codex until you trust
 * its hooks) is never reported as Active.
 */
#include "internal.h"
#include "cJSON.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int kai_agent_hooks_installed(const char *rel, const char *needle, int *detected);  /* manage.c */
char *kai_codex_hooks_path(void);                                                     /* install.c */

/* When did `agent` last really run Kai's hook? Every real call stamps
 * <kai home>/hookseen/<agent>; health probes don't. 0 = never. */
static long long last_hook_call(const char *agent) { return kai_hook_last_seen(agent); }

static void clock_str(long long t, char *out, size_t n) {
    time_t tt = (time_t)t;
    struct tm lt; localtime_r(&tt, &lt);
    time_t now = time(NULL); struct tm ln; localtime_r(&now, &ln);
    if (lt.tm_yday == ln.tm_yday && lt.tm_year == ln.tm_year) strftime(out, n, "%H:%M", &lt);
    else strftime(out, n, "%b %d", &lt);
}

typedef struct {
    const char *name, *key, *config;
    int installed, detected, ok;
    long long last_use;
    char problem[256];
} agent_state;

static void agent_measure(agent_state *a) {
    char needle[32];
    snprintf(needle, sizeof needle, "hook %s", a->key);
    a->installed = kai_agent_hooks_installed(a->config, needle, &a->detected);
    a->ok = 0;
    a->problem[0] = '\0';
    a->last_use = 0;
    if (!a->installed) return;
    kai_health h;
    kai_health_agent(a->key, a->config, &h);
    a->ok = h.ok;
    kai_strlcpy(a->problem, h.problem, sizeof a->problem);
    a->last_use = last_hook_call(a->key);
}

static const char *wall_word(int lvl, int app) {
    if (!app) return "not included";
    switch (lvl) {
    case 2: return "protecting";
    case 1: return "watching";
    case 0: return "off";
    default: return "not running";
    }
}

static int app_installed(void) { return kai_app_present(); }

/* Spec v2.1 A.1: the security contract, word for word wherever it's shown. */
static const char *CONTRACT =
    "Kai Preview checks supported actions inside Claude Code, Codex and Cursor before they run. It is an extra "
    "safety layer, not isolation or OS-level enforcement: hooks run with your permissions, cover only the actions "
    "each agent reports to them, and a program the agent runs can get around them. Codex runs hooks only after "
    "you trust them.";

/* What each agent's hooks receive, from docs/COVERAGE.md. */
static const char *agent_checks(const char *key) {
    if (!strcmp(key, "claude")) return "file tool reads and writes, shell commands, your submitted prompts, MCP tools, web fetches";
    if (!strcmp(key, "codex")) return "shell commands, your submitted prompts, MCP tools";
    return "file reads, shell commands, your submitted prompts, MCP tool arguments (secrets only)";
}

/* Claude Code: hooks switched off in its own settings? */
static int hooks_disabled(const agent_state *a) {
    if (strcmp(a->key, "claude")) return 0;
    char *p = kai_expand_home(a->config);
    size_t n = 0;
    char *t = p ? kai_read_file(p, 4 << 20, &n) : NULL;
    free(p);
    cJSON *o = t ? cJSON_Parse(t) : NULL;
    free(t);
    int off = cJSON_IsTrue(cJSON_GetObjectItem(o, "disableAllHooks"));
    cJSON_Delete(o);
    return off;
}

/* The entries are the ones this Kai installs (e.g. Claude Code's tool matcher
 * includes WebFetch). */
static int configured_current(const agent_state *a) {
    if (strcmp(a->key, "claude")) return 1;
    char *p = kai_expand_home(a->config);
    size_t n = 0;
    char *t = p ? kai_read_file(p, 4 << 20, &n) : NULL;
    free(p);
    int ok = t && strstr(t, "WebFetch") != NULL;
    free(t);
    return ok;
}

static void ago_str(long long t, char *out, size_t n) {
    long long s = (long long)time(NULL) - t;
    if (s < 120) snprintf(out, n, "just now");
    else if (s < 7200) snprintf(out, n, "%lld min ago", s / 60);
    else if (s < 172800) snprintf(out, n, "%lld h ago", s / 3600);
    else snprintf(out, n, "%lld days ago", s / 86400);
}

/* A.3: per agent, each item measured on its own. Returns 2 checking,
 * 1 partly, 0 not checking, -1 not installed. */
static int agent_report(agent_state *a) {
    agent_measure(a);
    if (!a->installed) {
        printf("  %-12s %s\n", a->name, a->detected ? "Not checking: Kai isn't installed for it (kai install)" : "Not detected");
        return -1;
    }
    int disabled = hooks_disabled(a), current = configured_current(a);
    int trusted;                     /* 1 yes, 0 unknown, 2 not needed */
    if (!strcmp(a->key, "codex")) trusted = a->last_use ? 1 : 0;
    else trusted = 2;
    long long st = kai_selftest_last(a->key);
    int word = (!a->ok || disabled || trusted == 0) ? 0 : !current ? 1 : 2;
    const char *w = word == 2 ? "Checking" : word == 1 ? "Partly checking" : "Not checking";
    printf("  %-12s %s\n", a->name, w);
    char sts[48] = "now";
    if (st) ago_str(st, sts, sizeof sts);
    printf("    Installed: yes · Configured: %s · Trusted: %s · Self-test: %s\n",
           disabled ? "hooks are switched off in its settings (disableAllHooks)"
                    : current ? "yes" : "from an older Kai (kai install " "again)",
           trusted == 2 ? "not needed" : trusted == 1 ? "yes (Codex has run Kai's hook)"
                        : "unknown: Codex runs hooks only after you trust them (in Codex: /hooks)",
           a->ok ? (st ? sts : "passed now") : (a->problem[0] ? a->problem : "failed"));
    if (a->ok && st) printf("      (self-test passed %s; checked again now: passed)\n", sts);
    long long when = 0;
    char ver[200], cfg[65];
    if (kai_live_info(a->key, &when, ver, sizeof ver, cfg, sizeof cfg)) {
        char nowver[200], nowcfg[65], ag[48];
        kai_agent_version(a->key, nowver, sizeof nowver);
        kai_agent_config_sha(a->config, nowcfg);
        ago_str(when, ag, sizeof ag);
        const char *since = strcmp(nowver, ver) ? "; the agent was updated since"
                          : strcmp(nowcfg, cfg) ? "; its hook settings changed since" : "; nothing changed since";
        printf("    Live verification: verified %s (%s)%s\n", ag, ver[0] ? ver : "version unknown", since);
    } else {
        printf("    Live verification: never. Run kai demo --live (uses the agent and its model quota)\n");
    }
    printf("    Checks: %s\n", agent_checks(a->key));
    return word;
}

int kai_cmd_status_text(void) {
    int app = app_installed();
    char *codex = kai_codex_hooks_path();
    agent_state agents[] = {
        {"Claude Code", "claude", "~/.claude/settings.json", 0, 0, 0, 0, ""},
        {"Codex", "codex", codex, 0, 0, 0, 0, ""},
        {"Cursor", "cursor", "~/.cursor/hooks.json", 0, 0, 0, 0, ""},
    };
    int words[3], installed = 0, checking = 0, any_on = 0;
    /* measure first, headline after */
    char *buf = NULL; size_t blen = 0;
    FILE *mem = open_memstream(&buf, &blen);
    FILE *saved = stdout;
    if (mem) stdout = mem;
    for (int i = 0; i < 3; i++) {
        words[i] = agent_report(&agents[i]);
        if (words[i] >= 0) installed++;
        if (words[i] == 2) checking++;
        if (words[i] >= 1) any_on++;
    }
    if (mem) { fflush(mem); stdout = saved; fclose(mem); }
    free(codex);
    const char *head = installed && checking == installed ? "Checking"
                     : any_on ? "Partly checking" : "Not checking";
    printf("Kai%s %s · %s\n", app ? "" : " Preview", KAI_VERSION, head);
    if (!app) printf("%s\nKai Preview checks inside your agents. OS-level protection for files and internet comes "
                     "with the Kai app in an upcoming release.\n", CONTRACT);
    printf("Agents\n%s", buf ? buf : "");
    free(buf);

    int cdet = 0, con = kai_browser_installed(&cdet);
    const char *chats;
    char chatbuf[300], want[32] = "", have[32] = "";
    {   /* the version Kai ships vs the one Chrome last reported */
        char mf[1300];
        snprintf(mf, sizeof mf, "%s/manifest.json", kai_browser_ext_dir());
        size_t ml = 0;
        char *mt = kai_read_file(mf, 1 << 16, &ml);
        cJSON *mo = mt ? cJSON_Parse(mt) : NULL;
        free(mt);
        const char *v = cJSON_GetStringValue(cJSON_GetObjectItem(mo, "version"));
        if (v) kai_strlcpy(want, v, sizeof want);
        cJSON_Delete(mo);
        kai_chat_extension_version(have, sizeof have, NULL);
    }
    if (!con) chats = cdet ? "Not checking: Kai isn't set up for Chrome (kai install chrome)" : "Not detected";
    else if (!kai_browser_extension_loaded()) chats = "Not checking: the Kai extension isn't loaded in Chrome";
    else if (want[0] && strcmp(have, want) != 0) {
        snprintf(chatbuf, sizeof chatbuf, "Not checking reliably: reload the Kai extension in Chrome (Kai has %s; "
                 "Chrome runs %s)", want, have[0] ? have : "an older copy that doesn't report its version");
        chats = chatbuf;
    }
    else {
        char *exe = kai_browser_host_exe();
        kai_health h; kai_health_chrome(exe, &h); free(exe);
        if (h.ok) chats = "Checking (sites not yet verified: see docs/COVERAGE.md)";
        else { snprintf(chatbuf, sizeof chatbuf, "Not checking: %s", h.problem); chats = chatbuf; }
    }
    printf("%-16s %s\n", "Chats (Chrome)", chats);

    int files = kai_wall_observed_level("storage"), internet = kai_wall_observed_level("network");
    if (!app)
        printf("%-16s %s\n", "OS enforcement", "Not included in Preview 1");
    else
        printf("%-16s Files: %s · Internet: %s%s\n", "OS enforcement", wall_word(files, 1),
               internet < 0 ? "not verified" : wall_word(internet, 1),
               kai_wall_paused("storage", (long long)time(NULL)) ? " (Kai is paused)" : "");

    printf("%-16s %s\n", "Not checked", "what a program the agent runs does on its own, tool results, other "
                                          "model traffic, and actions an agent doesn't report to its hooks "
                                          "(docs/COVERAGE.md)");

    int nl = 0; char verr[256] = "";
    struct stat st;
    int exists = stat(kai_audit_path(), &st) == 0;
    int intact = exists ? kai_audit_verify(NULL, &nl, verr, sizeof verr) == 0 : 1;
    if (intact && exists && kai_audit_verify_rotation(verr, sizeof verr) < 0) intact = 0;
    if (!exists) printf("%-16s %s\n", "Audit log", "Empty (nothing recorded yet)");
    else if (intact) printf("%-16s Healthy (%d records, chain intact)\n", "Audit log", nl);
    else printf("%-16s BROKEN: %s\n", "Audit log", verr);

    int ks = 0, kb = 0;
    kai_daily_counts(NULL, &ks, &kb);
    printf("%-16s %d action%s stopped (kai log show)\n", "Today", ks + kb, ks + kb == 1 ? "" : "s");
    if (!app) printf("%-16s %s\n", "Your rules", "kai rules · kai allow-file / allow-fetch / allow-mcp / allow-upload");

    {
        char d2[160];
        int ig = kai_policy_integrity(d2, sizeof d2);
        if (ig == KAI_POLICY_CHANGED) printf("%-16s %s\n", "Policy", "Kai's rules were changed outside Kai. Check them: kai policy show");
        else if (ig == KAI_POLICY_MISSING) printf("%-16s %s\n", "Policy", "Missing: tool checks stop every action. Run kai init");
    }
    printf("Run `kai doctor` for details.\n");
    return 0;
}

/* `kai doctor`: every check behind `kai status`, with what was looked at. */
int kai_cmd_doctor(void) {
    int problems = 0;
    printf("kai %s at %s\n", KAI_VERSION, kai_exe_path());

    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    /* A.6b: four separate states, each in its own words. */
    char idet[160];
    int integ = kai_policy_integrity(idet, sizeof idet);
    if (!p) {
        if (integ == KAI_POLICY_MISSING)
            printf("✗ policy: missing. Kai wrote %s and it's gone, so tool checks stop every action. Run kai init.\n",
                   kai_policy_file());
        else
            printf("✗ policy: malformed or unreadable (%s). Tool checks stop every action until it's fixed; "
                   "prompts are let through with a warning.\n", err);
        problems++;
    } else {
        char first[64];
        int unk = kai_policy_unknown(p, first, sizeof first);
        printf("✓ policy loads (%s)\n", kai_policy_source(p));
        if (unk) { printf("! policy: %d unrecognized rule%s (first: %s), not applied by this version of Kai\n",
                          unk, unk == 1 ? "" : "s", first); problems++; }
        kai_policy_free(p);
    }
    if (integ == KAI_POLICY_CHANGED) {
        printf("! policy changed outside Kai (%s). If you didn't edit it yourself, check it: kai policy show\n", idet);
        problems++;
    } else if (integ == KAI_POLICY_OK) {
        printf("✓ policy matches what Kai last wrote\n");
    }
    {
        char mp[1200];
        snprintf(mp, sizeof mp, "%s/migrations/channels.txt", kai_home());
        size_t mn = 0;
        char *mt = kai_read_file(mp, 1 << 16, &mn);
        if (mt) { printf("· %s", mt); free(mt); }
    }
    printf("· Limit: Kai can't detect a change made together with its fingerprint (%s/policy.sha256) by a program "
           "with your permissions, or prevent either.\n", kai_home());

    char *codex = kai_codex_hooks_path();
    agent_state agents[] = {
        {"Claude Code", "claude", "~/.claude/settings.json", 0, 0, 0, 0, ""},
        {"Codex", "codex", codex, 0, 0, 0, 0, ""},
        {"Cursor", "cursor", "~/.cursor/hooks.json", 0, 0, 0, 0, ""},
    };
    for (size_t i = 0; i < sizeof agents / sizeof agents[0]; i++) {
        agent_state *a = &agents[i];
        agent_measure(a);
        char *cfg = kai_expand_home(a->config);
        if (!a->installed) {
            printf("%s %s: hooks not installed in %s%s\n", a->detected ? "!" : "·", a->name, cfg,
                   a->detected ? " (the agent is used here: kai install)" : "");
        } else if (!a->ok) {
            printf("✗ %s: %s (config %s)\n", a->name, a->problem, cfg); problems++;
        } else {
            char used[16] = "never";
            if (a->last_use) clock_str(a->last_use, used, sizeof used);
            printf("✓ %s: hooks in %s answer a synthetic request (denied as expected); last real call: %s\n",
                   a->name, cfg, used);
            if (!a->last_use && !strcmp(a->key, "codex"))
                printf("  ! Codex hasn't run Kai's hooks yet: open Codex, run /hooks and trust them\n");
        }
        free(cfg);
    }
    free(codex);

    int cdet = 0;
    if (kai_browser_installed(&cdet)) {
        char *exe = kai_browser_host_exe();
        kai_health h; kai_health_chrome(exe, &h);
        if (h.ok) printf("✓ Chrome native host answers (%s)\n", exe ? exe : "?");
        else { printf("✗ Chrome native host: %s\n", h.problem); problems++; }
        printf("%s Chrome extension %s\n", kai_browser_extension_loaded() ? "✓" : "!",
               kai_browser_extension_loaded() ? "loaded" : "not loaded (Load unpacked from kai install chrome's folder)");
        free(exe);
    } else {
        printf("· Chats: Chrome native host not installed%s\n", cdet ? " (Chrome is here: kai install chrome)" : "");
    }

    int nl = 0; char verr[256] = "";
    struct stat st;
    if (stat(kai_audit_path(), &st) == 0) {
        if (kai_audit_verify(NULL, &nl, verr, sizeof verr) == 0 && kai_audit_verify_rotation(verr, sizeof verr) >= 0)
            printf("✓ audit log %s: %d records, hash chain intact, mode %o\n", kai_audit_path(), nl,
                   (unsigned)(st.st_mode & 0777));
        else { printf("✗ audit log: %s\n", verr); problems++; }
        if ((st.st_mode & 077) != 0) { printf("✗ audit log is readable by other users (mode %o; want 600)\n",
                                              (unsigned)(st.st_mode & 0777)); problems++; }
    } else {
        printf("· audit log: empty (nothing recorded yet)\n");
    }

    if (app_installed()) {
        /* B4: two measures, reported apart. Health: is each extension running,
         * is its heartbeat fresh, does it run the current policy. Coverage:
         * which agent work it actually attributes and checks. */
        char cur[16], fp[32], ts[32];
        kai_policy_fingerprint(cur, sizeof cur);
        printf("Extension health\n");
        const char *walls[2][2] = {{"storage", "Files"}, {"network", "Internet"}};
        for (int i = 0; i < 2; i++) {
            int lvl = kai_wall_observed_level(walls[i][0]);
            if (lvl < 0) {
                printf("  ! %s: no verified heartbeat (not running, or not verified)\n", walls[i][1]);
                continue;
            }
            long long age = kai_heartbeat_field(walls[i][0], "ts", ts, sizeof ts)
                          ? (long long)time(NULL) - atoll(ts) : -1;
            int have = kai_heartbeat_field(walls[i][0], "policy", fp, sizeof fp);
            int stale = have && strcmp(fp, cur) != 0;
            printf("  %s %s: running, %s, heartbeat %llds old, policy %s\n", stale ? "!" : "✓", walls[i][1],
                   wall_word(lvl, 1), age, !have ? "version not reported (older extension)"
                   : stale ? "not the current file yet (reloads within seconds)" : "current");
        }
        printf("Enforcement coverage\n");
        kai_policy *pol = kai_policy_load(NULL, err, sizeof err);
        kai_session *scan = NULL, *reg = NULL;
        int ns = 0, nr = 0, attributed = 0, total = 0;
        if (pol && kai_sessions_scan(pol, &scan, &ns) == 0) {
            if (kai_sessions_load(&reg, &nr) != 0) nr = 0;
            for (int i = 0; i < ns; i++) {
                if (scan[i].kind != KAI_KIND_SESSION) continue;
                total++;
                for (int j = 0; j < nr; j++)
                    if (reg[j].source == KAI_SESS_ES && reg[j].root_pid == scan[i].root_pid && kai_session_live(&reg[j])) {
                        attributed++; break;
                    }
            }
        }
        free(scan); free(reg);
        if (pol) kai_policy_free(pol);
        int f = kai_wall_observed_level("storage");
        if (f < 0) printf("  · Files: not running, so no agent session is attributed or checked by it\n");
        else printf("  %s Files: %d of %d running agent session%s attributed%s\n", attributed == total ? "✓" : "!",
                    attributed, total, total == 1 ? "" : "s",
                    attributed == total ? "" : " (the others get no session permissions until Files sees them)");
        char flows[32] = "", blocked[32] = "";
        if (kai_heartbeat_field("network", "agent_flows", flows, sizeof flows)) {
            kai_heartbeat_field("network", "blocked", blocked, sizeof blocked);
            printf("  · Internet: %s agent connection%s seen, %s blocked since the extension started%s\n", flows,
                   strcmp(flows, "1") ? "s" : "", blocked[0] ? blocked : "0",
                   strcmp(flows, "0") ? "" : " (none seen: nothing measured yet)");
        } else {
            printf("  · Internet: not running or not verified, so no agent connection is checked by it\n");
        }
        printf("  · Known gaps: while an extension restarts or after it crashes, its checks stop until it is "
               "back (fail-open). See docs/RUNTIME.md.\n");
    } else {
        printf("· OS protection (Files, Internet): not included in this preview\n");
    }
    printf("· Accessibility: not measured - an agent's host app with Accessibility permission could click "
           "Kai's buttons; check System Settings > Privacy & Security > Accessibility\n");

    printf("%s\n", problems ? "Problems found." : "No problems found.");
    return problems ? 1 : 0;
}
