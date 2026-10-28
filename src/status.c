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

/* "Active (hooks verified 09:14, last used 08:50)" etc. Returns 1 if active. */
static int agent_line(const agent_state *a, char *out, size_t n) {
    char now[16], used[16] = "";
    clock_str((long long)time(NULL), now, sizeof now);
    if (a->last_use) clock_str(a->last_use, used, sizeof used);
    if (!a->installed) {
        snprintf(out, n, a->detected ? "Not configured — run: kai install %s" : "Not detected", a->key);
        return 0;
    }
    if (!a->ok) { snprintf(out, n, "Degraded: %s", a->problem[0] ? a->problem : "hook check failed"); return 0; }
    if (!a->last_use) {
        if (!strcmp(a->key, "codex"))
            snprintf(out, n, "Hooks installed, not yet run by Codex — trust Kai's hooks in Codex (/hooks)");
        else
            snprintf(out, n, "Installed (hooks verified %s), not used yet", now);
        return 0;
    }
    snprintf(out, n, "Active (hooks verified %s, last used %s)", now, used);
    return 1;
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

static int app_installed(void) {
    struct stat st;
    return stat("/Applications/Kai.app/Contents/Library/SystemExtensions", &st) == 0;
}

int kai_cmd_status_text(void) {
    int app = app_installed();
    printf("Kai%s %s\n", app ? "" : " Preview", KAI_VERSION);

    char *codex = kai_codex_hooks_path();
    agent_state agents[] = {
        {"Claude Code", "claude", "~/.claude/settings.json", 0, 0, 0, 0, ""},
        {"Codex", "codex", codex, 0, 0, 0, 0, ""},
        {"Cursor", "cursor", "~/.cursor/hooks.json", 0, 0, 0, 0, ""},
    };
    int active = 0, configured = 0;
    printf("Agent checks\n");
    for (size_t i = 0; i < sizeof agents / sizeof agents[0]; i++) {
        agent_measure(&agents[i]);
        char line[400];
        active += agent_line(&agents[i], line, sizeof line);
        configured += agents[i].installed;
        printf("  %-14s %s\n", agents[i].name, line);
    }
    free(codex);

    int cdet = 0, con = kai_browser_installed(&cdet);
    const char *chats;
    char chatbuf[300];
    if (!con) chats = cdet ? "Not configured — run: kai install chrome" : "Not detected";
    else if (!kai_browser_extension_loaded()) chats = "Native host installed, extension not loaded in Chrome";
    else {
        char *exe = kai_browser_host_exe();
        kai_health h; kai_health_chrome(exe, &h); free(exe);
        if (h.ok) chats = "Active (extension connected)";
        else { snprintf(chatbuf, sizeof chatbuf, "Degraded: %s", h.problem); chats = chatbuf; }
    }
    printf("%-16s %s\n", "Chats (Chrome)", chats);

    int files = kai_wall_observed_level("storage"), internet = kai_wall_observed_level("network");
    if (!app)
        printf("%-16s %s\n", "OS protection", "Not included in this preview (Files, Internet)");
    else
        printf("%-16s Files: %s · Internet: %s%s\n", "OS protection", wall_word(files, 1),
               internet < 0 ? "not verified" : wall_word(internet, 1),
               kai_wall_paused("storage", (long long)time(NULL)) ? " (Kai is paused)" : "");

    const char *coverage;
    if (active == 0) coverage = configured ? "None verified yet: no agent has used Kai's checks" : "None: no agent configured";
    else if (app && files == 2 && internet == 2) coverage = "Agent checks + Files + Internet";
    else coverage = "Partial: agent checks only";
    printf("%-16s %s\n", "Coverage", coverage);

    int nl = 0; char verr[256] = "";
    struct stat st;
    int exists = stat(kai_audit_path(), &st) == 0;
    int intact = exists ? kai_audit_verify(NULL, &nl, verr, sizeof verr) == 0 : 1;
    if (intact && exists && kai_audit_verify_rotation(verr, sizeof verr) < 0) intact = 0;
    if (!exists) printf("%-16s %s\n", "Audit log", "Empty (nothing recorded yet)");
    else if (intact) printf("%-16s Healthy (%d records, chain intact)\n", "Audit log", nl);
    else printf("%-16s BROKEN: %s\n", "Audit log", verr);

    printf("Run `kai doctor` for details.\n");
    return 0;
}

/* `kai doctor`: every check behind `kai status`, with what was looked at. */
int kai_cmd_doctor(void) {
    int problems = 0;
    printf("kai %s at %s\n", KAI_VERSION, kai_exe_path());

    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { printf("✗ policy: %s\n", err); problems++; }
    else { printf("✓ policy loads (%s)\n", kai_policy_source(p)); kai_policy_free(p); }

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
        int f = kai_wall_observed_level("storage"), n = kai_wall_observed_level("network");
        printf("%s Files (storage wall): %s\n", f >= 1 ? "✓" : "!",
               f < 0 ? "no verified heartbeat (not running)" : wall_word(f, 1));
        printf("%s Internet (network wall): %s\n", n >= 1 ? "✓" : "!",
               n < 0 ? "no verified heartbeat (not running or not verified)" : wall_word(n, 1));
    } else {
        printf("· OS protection (Files, Internet): not included in this preview\n");
    }
    printf("· Accessibility: not measured - an agent's host app with Accessibility permission could click "
           "Kai's buttons; check System Settings > Privacy & Security > Accessibility\n");

    printf("%s\n", problems ? "Problems found." : "No problems found.");
    return problems ? 1 : 0;
}
