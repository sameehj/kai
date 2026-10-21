/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Storage-wall decision tests: kai_storage_open_allowed, with no OS involved.
 * Its own file so the suite doesn't read tests/run_tests.c (which carries
 * secret fixtures the storage wall itself now guards).
 */
#include "kai.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

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

/* Monotonic nanoseconds, for the profiler-cost microbench only. */
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Exercise the ES-handler profiler: default off, enable, record, export JSON
 * that carries only numbers, reset, and measure its own per-call cost enabled
 * vs disabled (requirement: profiler must be cheap and leak no user data). */
static void test_profiler(void) {
    printf("storage profiler\n");

    kai_prof_reset();
    CHECK(kai_prof_enabled() == 0, "profiler is off by default");

    /* Disabled: record must be a no-op (nothing counted). */
    kai_prof_record((int)KAI_PROF_TOTAL, 1234);
    char buf[2048];
    size_t n = kai_prof_export_json(buf, sizeof buf);
    CHECK(n > 0 && n < sizeof buf, "export returns a bounded length");
    CHECK(strstr(buf, "\"total\":{\"count\":0") != NULL, "disabled record counts nothing");
    CHECK(strstr(buf, "\"enabled\":0") != NULL, "export reports disabled state");

    /* Enable and record a known distribution across stages. */
    kai_prof_set_enabled(1);
    CHECK(kai_prof_enabled() == 1, "profiler enables");
    for (int i = 0; i < 1000; i++) kai_prof_record((int)KAI_PROF_POLICY, 1000);  /* 1us each */
    kai_prof_record((int)KAI_PROF_POLICY, 1000000);                              /* one 1ms outlier */
    n = kai_prof_export_json(buf, sizeof buf);
    CHECK(strstr(buf, "\"policy\":{\"count\":1001") != NULL, "counts every recorded sample");
    CHECK(strstr(buf, "\"max\":1000.000") != NULL, "max is exact (1000us = 1ms outlier)");

    /* Export must never leak a path or a process name — numbers only. */
    CHECK(strstr(buf, "/") == NULL, "export contains no path separators");
    CHECK(strstr(buf, ".ssh") == NULL && strstr(buf, ".env") == NULL, "export names no protected file");

    /* Truncation contract: a short buffer truncates safely and reports the
     * full length needed. */
    char small[16];
    size_t need = kai_prof_export_json(small, sizeof small);
    CHECK(need >= sizeof small, "short buffer reports full length needed");
    CHECK(small[sizeof small - 1] == '\0', "short buffer stays NUL-terminated");

    /* Reset clears everything. */
    kai_prof_reset();
    n = kai_prof_export_json(buf, sizeof buf);
    CHECK(strstr(buf, "\"policy\":{\"count\":0") != NULL, "reset clears counts");

    /* Profiler-cost microbench: per-call time enabled vs disabled. Informational
     * (printed, not asserted) so it never flakes CI, but it documents that the
     * hot-path cost of recording is small. */
    const int N = 2000000;
    kai_prof_set_enabled(0);
    uint64_t t0 = now_ns();
    for (int i = 0; i < N; i++) kai_prof_record((int)KAI_PROF_TOTAL, 500);
    uint64_t off = now_ns() - t0;
    kai_prof_set_enabled(1);
    t0 = now_ns();
    for (int i = 0; i < N; i++) kai_prof_record((int)KAI_PROF_TOTAL, 500);
    uint64_t on = now_ns() - t0;
    kai_prof_set_enabled(0);
    kai_prof_reset();
    printf("  info profiler cost: disabled %.2f ns/call, enabled %.2f ns/call\n",
           (double)off / N, (double)on / N);
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

    /* Kai's own files and hook settings: denied to agents both ways. Only
     * Kai's own code-signed process is let through, by the ES client before
     * this function — the engine itself blocks every agent. */
    CHECK(may(p, 1, "/work/.claude/settings.json") == 0, "agent denied reading Claude hook settings");
    CHECK(mayWrite(p, 1, "/work/.claude/settings.json") == 0, "agent denied writing Claude hook settings");
    CHECK(may(p, 1, "/work/repo/.cursor/hooks.json") == 0, "agent denied reading project Cursor hooks");
    CHECK(mayWrite(p, 1, "/work/repo/.cursor/hooks.json") == 0, "agent denied writing Cursor hooks");

    why[0] = '\0';
    kai_storage_open_allowed(p, 1, 0, "/work/.ssh/id_rsa", why, sizeof why);
    CHECK(strstr(why, ".ssh") != NULL, "denial names the matching rule");

    /* A NULL path or NULL policy must not crash and defaults to allow. */
    CHECK(kai_storage_open_allowed(p, 1, 0, NULL, why, sizeof why) == 1, "NULL path allowed, no crash");
    CHECK(kai_storage_open_allowed(NULL, 1, 0, "/x", why, sizeof why) == 1, "NULL policy allowed, no crash");
    kai_policy_free(p);

    test_profiler();

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "all passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
