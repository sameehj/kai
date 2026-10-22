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
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <dirent.h>

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

/* ---- Scoped Approvals (grant engine) ---- */
static const unsigned char GKEY[] = "test-approval-key-0123456789abcdef";
#define GKEYLEN (sizeof GKEY - 1)

static kai_grant mkgrant(const char *res, int op, int scope, int strength,
                         int pid, unsigned long long pv, long long expires) {
    kai_grant g;
    memset(&g, 0, sizeof g);
    snprintf(g.id, sizeof g.id, "grant-%d-%d", pid, op);
    g.created_utc = 1000;
    g.expires_utc = expires;
    g.pid = pid;
    g.pidversion = pv;
    snprintf(g.agent, sizeof g.agent, "claude");
    g.strength = strength;
    snprintf(g.resource, sizeof g.resource, "%s", res);
    g.op = op;
    g.scope = scope;
    snprintf(g.approved_by, sizeof g.approved_by, "console-user");
    kai_grant_sign(&g, GKEY, GKEYLEN);
    return g;
}

static void test_grants(void) {
    printf("scoped approvals (grant engine)\n");
    const long long NOW = 1000;
    kai_policy *pol = mk("protect /secrets\n");
    CHECK(pol != NULL, "grant test policy built");

    kai_grant_subject sub = { .pid = 100, .pidversion = 5, .agent = "claude",
                              .strength = KAI_ID_STRONG };
    char why[256];

    /* HMAC sign/verify + tamper detection */
    kai_grant g = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                          KAI_ID_STRONG, 100, 5, 1000000);
    CHECK(kai_grant_hmac_ok(&g, GKEY, GKEYLEN) == 1, "signed grant verifies");
    kai_grant tampered = g; tampered.op = KAI_OP_WRITE; /* field changed, old mac */
    CHECK(kai_grant_hmac_ok(&tampered, GKEY, GKEYLEN) == 0, "tampered grant fails HMAC");
    kai_grant wrongkey = g;
    CHECK(kai_grant_hmac_ok(&wrongkey, (const unsigned char *)"nope", 4) == 0,
          "grant signed with another key fails HMAC");

    /* 1. no grant -> soft-protected path denied */
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &sub,
                             NULL, 0, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "unauthorized read of protected path denied");

    /* 2. a matching grant allows exactly that resource+op */
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &sub,
                             &g, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 1,
          "grant permits the intended resource+op");

    /* 3. unrelated protected resource stays denied (exact match, symlink-safe) */
    CHECK(kai_storage_decide(pol, "/secrets/other", NULL, KAI_OP_READ, &sub,
                             &g, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "grant does not cover a different protected file");

    /* 4. op mismatch denied */
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_WRITE, &sub,
                             &g, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "grant for read does not allow write");

    /* 5. expiry (enforcement-time) */
    kai_grant expg = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                             KAI_ID_STRONG, 100, 5, 500 /* already past at NOW=1000 */);
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &sub,
                             &expg, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "expired grant denied");

    /* 6/7/8. different process (reuse / child / concurrent session) cannot reuse */
    kai_grant_subject other = { .pid = 999, .pidversion = 5, .agent = "claude",
                                .strength = KAI_ID_STRONG };
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &other,
                             &g, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "a different pid cannot reuse the grant");
    kai_grant_subject reused = { .pid = 100, .pidversion = 6, .agent = "claude",
                                 .strength = KAI_ID_STRONG };
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &reused,
                             &g, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "same pid, new pidversion (reuse/re-exec) cannot reuse the grant");

    /* 11. agent-forged grant (bad HMAC) is never honored */
    kai_grant forged = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                               KAI_ID_STRONG, 100, 5, 1000000);
    snprintf(forged.hmac, sizeof forged.hmac,
             "0000000000000000000000000000000000000000000000000000000000000000");
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &sub,
                             &forged, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "grant with a forged HMAC is not honored");

    /* builtin/control path: NO grant can override it */
    kai_grant ctrl = mkgrant("/home/u/.claude/settings.json", KAI_OP_READ,
                             KAI_GRANT_PROCESS, KAI_ID_STRONG, 100, 5, 1000000);
    CHECK(kai_storage_decide(pol, "/home/u/.claude/settings.json", NULL, KAI_OP_READ,
                             &sub, &ctrl, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "a grant cannot override an un-exemptable control path");

    /* weak identity: eligible for one-shot only, never process scope */
    kai_grant_subject weak = { .pid = 100, .pidversion = 5, .agent = "claude",
                               .strength = KAI_ID_WEAK };
    kai_grant wkproc = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                               KAI_ID_WEAK, 100, 5, 1000000);
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &weak,
                             &wkproc, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 0,
          "weak identity cannot hold a process-scoped grant");
    kai_grant wkone = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_ONESHOT,
                              KAI_ID_WEAK, 100, 5, 1000000);
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &weak,
                             &wkone, 1, NOW, GKEY, GKEYLEN, why, sizeof why) == 1,
          "weak identity may hold a one-shot grant");

    /* JSON round-trip preserves fields and HMAC validity */
    char *js = kai_grant_to_json(&g);
    CHECK(js != NULL, "grant serializes to JSON");
    kai_grant back;
    CHECK(js && kai_grant_from_json(js, &back) == 1, "grant parses back from JSON");
    CHECK(kai_grant_hmac_ok(&back, GKEY, GKEYLEN) == 1, "round-tripped grant still verifies");
    free(js);

    /* load from a directory */
    char dir[] = "/tmp/kai-grant-testXXXXXX";
    if (mkdtemp(dir)) {
        char fp[512];
        snprintf(fp, sizeof fp, "%s/g.json", dir);
        char *j2 = kai_grant_to_json(&g);
        FILE *f = fopen(fp, "w");
        if (f && j2) { fputs(j2, f); fclose(f); }
        free(j2);
        kai_grant *loaded = NULL; int ln = 0;
        kai_grants_load(dir, &loaded, &ln);
        CHECK(ln == 1, "grants load from directory");
        CHECK(ln == 1 && kai_grant_match(loaded, ln, &sub, "/secrets/data",
                                         KAI_OP_READ, NOW, GKEY, GKEYLEN) == 0,
              "loaded grant matches the subject");
        free(loaded);
        unlink(fp); rmdir(dir);
    }

    kai_policy_free(pol);
}

/* ---- M2 approval store ---- */
static void write_grant_file(const char *dir, const kai_grant *g) {
    char fp[512];
    snprintf(fp, sizeof fp, "%s/%s.json", dir, g->id);
    char *js = kai_grant_to_json(g);
    FILE *f = fopen(fp, "w");
    if (f && js) { fputs(js, f); fclose(f); }
    free(js);
}

typedef struct { kai_approval_store *s; kai_grant_subject sub; int allow; } th_arg;
static void *decide_thread(void *p) {
    th_arg *a = p;
    char why[256];
    a->allow = kai_approval_store_decide(a->s, "/secrets/data", NULL, KAI_OP_READ,
                                         &a->sub, 1000, why, sizeof why);
    return NULL;
}

static long long now_ns2(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

static void test_approval_store(void) {
    printf("approval store (M2)\n");
    char dir[] = "/tmp/kai-store-testXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp for store test"); return; }
    char gdir[600], polp[600];
    snprintf(gdir, sizeof gdir, "%s/grants", dir);
    snprintf(polp, sizeof polp, "%s/policy", dir);
    mkdir(gdir, 0700);
    FILE *pf = fopen(polp, "w");
    if (pf) { fputs("protect /secrets\n", pf); fclose(pf); }

    kai_grant_subject sub = { .pid = 100, .pidversion = 5, .agent = "claude",
                              .strength = KAI_ID_STRONG };
    char why[256];

    /* process-scoped grant: repeatable allow */
    kai_grant pg = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                           KAI_ID_STRONG, 100, 5, 1000000);
    write_grant_file(gdir, &pg);

    kai_approval_store *s = kai_approval_store_open(polp, gdir, GKEY, GKEYLEN, 0);
    CHECK(s != NULL, "approval store opens");
    CHECK(kai_approval_store_count(s) == 1, "store loaded one grant");
    unsigned long gen0 = kai_approval_store_generation(s);

    CHECK(kai_approval_store_decide(s, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 1, "process grant allows");
    CHECK(kai_approval_store_decide(s, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 1, "process grant is repeatable");
    CHECK(kai_approval_store_decide(s, "/secrets/other", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0, "store denies a different resource");

    /* immediate revocation against the RUNNING store (no reload) */
    int rev = kai_approval_store_revoke(s, pg.id);
    CHECK(rev == 1, "revoke removes the grant");
    CHECK(kai_approval_store_generation(s) > gen0, "revoke bumps the generation");
    CHECK(kai_approval_store_decide(s, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0,
          "revoked grant denies immediately (no reinitialization)");

    /* reload picks up a newly added grant and bumps the generation */
    kai_grant pg2 = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                            KAI_ID_STRONG, 100, 5, 1000000);
    write_grant_file(gdir, &pg2);
    unsigned long gen1 = kai_approval_store_generation(s);
    int swapped = kai_approval_store_reload(s, 1);
    CHECK(swapped == 1, "force reload swaps the snapshot");
    CHECK(kai_approval_store_generation(s) > gen1, "reload bumps the generation");
    CHECK(kai_approval_store_decide(s, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 1, "reloaded grant is live");
    kai_approval_store_revoke(s, pg2.id);

    /* ONE-SHOT atomic consume under concurrency: exactly one winner */
    kai_grant one = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_ONESHOT,
                            KAI_ID_STRONG, 100, 5, 1000000);
    write_grant_file(gdir, &one);
    kai_approval_store_reload(s, 1);
    enum { NTH = 16 };
    pthread_t th[NTH];
    th_arg args[NTH];
    for (int i = 0; i < NTH; i++) { args[i].s = s; args[i].sub = sub; args[i].allow = -1;
        pthread_create(&th[i], NULL, decide_thread, &args[i]); }
    int wins = 0;
    for (int i = 0; i < NTH; i++) { pthread_join(th[i], NULL); wins += (args[i].allow == 1); }
    printf("  info one-shot concurrent winners = %d (expect 1)\n", wins);
    CHECK(wins == 1, "one-shot grant consumed by exactly one of 16 concurrent deciders");
    CHECK(kai_approval_store_decide(s, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0, "one-shot denies after consumption");

    kai_approval_store_close(s);

    /* fail-closed: a store over a nonexistent grants dir denies protected paths */
    kai_approval_store *s2 = kai_approval_store_open(polp, "/tmp/kai-no-such-dir-xyz",
                                                     GKEY, GKEYLEN, 0);
    CHECK(s2 && kai_approval_store_decide(s2, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                          1000, why, sizeof why) == 0,
          "missing grants dir fails closed (protected path denied)");
    CHECK(s2 && kai_approval_store_decide(s2, "/ordinary/file", NULL, KAI_OP_READ, &sub,
                                          1000, why, sizeof why) == 1,
          "unprotected path still allowed with no grants");
    kai_approval_store_close(s2);

    /* perf: decide throughput (read-lock + match), informational */
    kai_grant pg3 = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                            KAI_ID_STRONG, 100, 5, 1000000);
    write_grant_file(gdir, &pg3);
    kai_approval_store *s3 = kai_approval_store_open(polp, gdir, GKEY, GKEYLEN, 60);
    const int N = 200000;
    long long t0 = now_ns2();
    volatile int acc = 0;
    for (int i = 0; i < N; i++)
        acc += kai_approval_store_decide(s3, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                         1000, why, sizeof why);
    long long dt = now_ns2() - t0;
    printf("  info store decide (process-grant allow): %.3f us/call\n", (double)dt / N / 1000.0);
    kai_approval_store_close(s3);

    /* cleanup */
    DIR *d = opendir(gdir);
    if (d) { struct dirent *e; char fp[700];
        while ((e = readdir(d))) { if (e->d_name[0]=='.') continue;
            snprintf(fp,sizeof fp,"%s/%s",gdir,e->d_name); unlink(fp); } closedir(d); }
    unlink(polp); rmdir(gdir); rmdir(dir);
    (void)acc;
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
    test_grants();
    test_approval_store();

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "all passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
