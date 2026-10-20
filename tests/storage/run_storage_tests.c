/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Storage-wall decision tests: kai_storage_open_allowed, with no OS involved.
 * Its own file so the suite doesn't read tests/run_tests.c (which carries
 * secret fixtures the storage wall itself now guards).
 */
#include "kai.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   %s\n", msg); } \
    else { printf("  FAIL %s\n", msg); failures++; } \
} while (0)

/* allow=1 means "may open"; deny=0. */
static int may(const kai_policy *p, int agent, const char *path) {
    char why[256];
    return kai_storage_open_allowed(p, agent, 0, path, why, sizeof why);
}
static int mayWrite(const kai_policy *p, int agent, const char *path) {
    char why[256];
    return kai_storage_open_allowed(p, agent, 1, path, why, sizeof why);
}

static kai_policy *mk(const char *text) {
    char err[256] = "";
    kai_policy *p = kai_policy_from_string(text, err, sizeof err);
    if (!p) { fprintf(stderr, "policy parse failed: %s\n", err); }
    return p;
}

int main(void) {
    printf("storage wall decisions\n");

    /* Absolute protect paths so the test doesn't depend on ~ expanding to any
     * particular home (kai_path_protected expands ~ to the running user's). */
    const char *rules =
        "protect /work/.ssh\n"
        "protect /work/project/.env\n"
        "allow /work/project/.env.example\n";

    /* Off (the default): everything is allowed, even for agents. */
    char body_off[512];
    snprintf(body_off, sizeof body_off, "storage off\n%s", rules);
    kai_policy *off = mk(body_off);
    CHECK(kai_policy_storage_mode(off) == KAI_STORAGE_OFF, "storage off parsed");
    CHECK(may(off, 1, "/work/.ssh/id_rsa") == 1, "off: agent may read a protected key");
    kai_policy_free(off);

    /* Log: still allowed, but the caller gets a reason to log. */
    char body_log[512];
    snprintf(body_log, sizeof body_log, "storage log\n%s", rules);
    kai_policy *log = mk(body_log);
    char why[256] = "";
    CHECK(kai_policy_storage_mode(log) == KAI_STORAGE_LOG, "storage log parsed");
    CHECK(kai_storage_open_allowed(log, 1, 0, "/work/.ssh/id_rsa", why, sizeof why) == 1,
          "log: agent read is allowed");
    CHECK(why[0] != '\0', "log: a protected read still reports why");
    kai_policy_free(log);

    /* Block: agents denied for protected paths; everyone else untouched. */
    char body[512];
    snprintf(body, sizeof body, "storage block\n%s", rules);
    kai_policy *p = mk(body);
    CHECK(p != NULL, "policy built");
    CHECK(kai_policy_storage_mode(p) == KAI_STORAGE_BLOCK, "storage block parsed");

    /* Secrets (user protect rules): denied to agents both reading and writing. */
    CHECK(may(p, 1, "/work/.ssh/id_rsa") == 0, "agent denied reading an ssh key");
    CHECK(mayWrite(p, 1, "/work/.ssh/id_rsa") == 0, "agent denied writing an ssh key");
    CHECK(may(p, 1, "/work/project/.env") == 0, "agent denied .env");
    CHECK(may(p, 1, "/work/project/.env.example") == 1, "allow-listed .env.example permitted");
    CHECK(may(p, 1, "/work/project/main.c") == 1, "agent may read ordinary file");

    /* A non-agent process is never constrained. */
    CHECK(may(p, 0, "/work/.ssh/id_rsa") == 1, "non-agent reads anything");

    /* Kai's own files and hook settings aren't secret: agents may READ them
     * (so Kai's tools can load the policy) but may not WRITE them (tamper). */
    CHECK(may(p, 1, "/work/.claude/settings.json") == 1, "agent may read Claude hook settings");
    CHECK(mayWrite(p, 1, "/work/.claude/settings.json") == 0, "agent denied writing Claude hook settings");
    CHECK(may(p, 1, "/work/repo/.cursor/hooks.json") == 1, "agent may read project Cursor hooks");
    CHECK(mayWrite(p, 1, "/work/repo/.cursor/hooks.json") == 0, "agent denied writing Cursor hooks");

    why[0] = '\0';
    kai_storage_open_allowed(p, 1, 0, "/work/.ssh/id_rsa", why, sizeof why);
    CHECK(strstr(why, ".ssh") != NULL, "denial names the matching rule");

    /* A NULL path or NULL policy must not crash and defaults to allow. */
    CHECK(kai_storage_open_allowed(p, 1, 0, NULL, why, sizeof why) == 1, "NULL path allowed, no crash");
    CHECK(kai_storage_open_allowed(NULL, 1, 0, "/x", why, sizeof why) == 1, "NULL policy allowed, no crash");
    kai_policy_free(p);

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "all passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
