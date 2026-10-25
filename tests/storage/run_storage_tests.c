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
#include <sys/fcntl.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdint.h>

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
    snprintf(g.id, sizeof g.id, "grant-%d-%d-%d", pid, op, scope); /* scope in id: one-shot marker won't poison process-grant tests */
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

static kai_grant mkgrant2(const char *res, int op, int scope, int strength,
                          int pid, unsigned long long pv, long long expires,
                          const char *session, const char *project, int dest) {
    kai_grant g;
    memset(&g, 0, sizeof g);
    snprintf(g.id, sizeof g.id, "g2-%d-%d-%d", pid, op, scope);
    g.created_utc = 1000; g.expires_utc = expires; g.pid = pid; g.pidversion = pv;
    snprintf(g.agent, sizeof g.agent, "claude");
    g.strength = strength;
    snprintf(g.resource, sizeof g.resource, "%s", res);
    g.op = op; g.scope = scope;
    snprintf(g.approved_by, sizeof g.approved_by, "console-user");
    g.grant_version = 2;
    if (session) snprintf(g.session_id, sizeof g.session_id, "%s", session);
    if (project) snprintf(g.project, sizeof g.project, "%s", project);
    g.dest_kind = dest;
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

    /* ---- v2: session + project binding, and endpoint (network) grants ---- */
    kai_grant_subject s1 = { .pid = 100, .pidversion = 5, .agent = "claude",
                             .strength = KAI_ID_STRONG, .session_id = "S1", .project = "/proj" };
    kai_grant_subject s2 = { .pid = 100, .pidversion = 5, .agent = "claude",
                             .strength = KAI_ID_STRONG, .session_id = "S2", .project = "/proj" };
    kai_grant_subject s0 = { .pid = 100, .pidversion = 5, .agent = "claude",
                             .strength = KAI_ID_STRONG }; /* no session/project */

    kai_grant sg = mkgrant2("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS, KAI_ID_STRONG,
                            100, 5, 1000000, "S1", NULL, KAI_DEST_PATH);
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &s1, &sg, 1,
                             1000, GKEY, GKEYLEN, why, sizeof why) == 1, "v2 session grant allows the bound session");
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &s2, &sg, 1,
                             1000, GKEY, GKEYLEN, why, sizeof why) == 0, "v2 session grant denies a different session");
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &s0, &sg, 1,
                             1000, GKEY, GKEYLEN, why, sizeof why) == 0, "v2 session grant denies a process with no session");

    kai_grant pgj = mkgrant2("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS, KAI_ID_STRONG,
                             100, 5, 1000000, NULL, "/proj", KAI_DEST_PATH);
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &s1, &pgj, 1,
                             1000, GKEY, GKEYLEN, why, sizeof why) == 1, "v2 project grant allows the bound project");
    kai_grant_subject sp2 = { .pid = 100, .pidversion = 5, .agent = "claude",
                              .strength = KAI_ID_STRONG, .project = "/other" };
    CHECK(kai_storage_decide(pol, "/secrets/data", NULL, KAI_OP_READ, &sp2, &pgj, 1,
                             1000, GKEY, GKEYLEN, why, sizeof why) == 0, "v2 project grant denies a different project");

    /* endpoint (network) grant: op=connect, resource = host:port, exact match */
    kai_grant eg = mkgrant2("example.com:443", KAI_OP_CONNECT, KAI_GRANT_PROCESS, KAI_ID_STRONG,
                            100, 5, 1000000, "S1", NULL, KAI_DEST_ENDPOINT);
    CHECK(kai_grant_match(&eg, 1, &s1, "example.com:443", KAI_OP_CONNECT, 1000, GKEY, GKEYLEN) == 0,
          "v2 endpoint grant matches host:port for a connect");
    CHECK(kai_grant_match(&eg, 1, &s1, "evil.com:443", KAI_OP_CONNECT, 1000, GKEY, GKEYLEN) == -1,
          "v2 endpoint grant does not match a different host");
    CHECK(kai_grant_match(&eg, 1, &s1, "example.com:443", KAI_OP_READ, 1000, GKEY, GKEYLEN) == -1,
          "v2 endpoint grant does not match a different op");

    /* read-allow / write-block classification of control paths */
    CHECK(kai_control_read_allowed(".claude/settings.json") == 1, "agent may READ its Claude hook config");
    CHECK(kai_control_read_allowed(".cursor/hooks.json") == 1, "agent may READ its Cursor hook config");
    CHECK(kai_control_read_allowed(".codex/config.toml") == 1, "agent may READ its Codex config");
    CHECK(kai_control_read_allowed("~/.kai") == 0, "agent may NOT read Kai's home (key/audit/policy)");
    CHECK(kai_rule_is_kai_home("~/.kai") == 1, "Kai home is recognized");
    CHECK(kai_control_read_allowed(".env") == 0, "a secret rule is not a readable control path");

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

static int file_contains(const char *path, const char *needle) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char buf[65536];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = '\0';
    return strstr(buf, needle) != NULL;
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

/* Concurrency-during-mutation: deciders race a mutator that rewrites the policy
 * file, churns a grant file, and force-reloads. Shared context (single test). */
static struct { kai_approval_store *s; char polp[600]; char gdir[600]; volatile int stop; } MUT;

static void *mut_decider(void *p) {   /* returns count of ILLEGAL control-path allows */
    long ctrl_allowed = 0;
    kai_grant_subject sub = { .pid = 100, .pidversion = 5, .agent = "claude", .strength = KAI_ID_STRONG };
    char why[256];
    for (int i = 0; i < 4000; i++) {
        long long now = (long long)time(NULL);
        kai_approval_store_decide(MUT.s, "/secrets/data", NULL, KAI_OP_READ, &sub, now, why, sizeof why);
        /* a builtin/control path must NEVER be granted, even mid-mutation */
        if (kai_approval_store_decide(MUT.s, "/home/u/.claude/settings.json", NULL,
                                      KAI_OP_READ, &sub, now, why, sizeof why) == 1) ctrl_allowed++;
    }
    (void)p;
    return (void *)(intptr_t)ctrl_allowed;
}

static void *mut_mutator(void *p) {
    (void)p;
    kai_grant churn = mkgrant("/secrets/churn", KAI_OP_READ, KAI_GRANT_PROCESS,
                              KAI_ID_STRONG, 100, 5, (long long)time(NULL) + 3600);
    char fp[700];
    snprintf(fp, sizeof fp, "%s/%s.json", MUT.gdir, churn.id);
    for (int i = 0; !MUT.stop && i < 100000; i++) {
        FILE *f = fopen(MUT.polp, "w");                 /* rewrite policy (mtime churn) */
        if (f) { fputs((i & 1) ? "protect /secrets\nprotect /other\n" : "protect /secrets\n", f); fclose(f); }
        if (i & 1) { char *js = kai_grant_to_json(&churn); FILE *g = fopen(fp, "w");
                     if (g && js) { fputs(js, g); fclose(g); } free(js); }
        else unlink(fp);
        kai_approval_store_reload(MUT.s, 1);            /* concurrent atomic snapshot swaps */
    }
    return NULL;
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
    // KAI_HOME was pointed at a temp dir in main(); audit lands there, hermetic.
    const char *kaihome = getenv("KAI_HOME");
    char alog[700]; snprintf(alog, sizeof alog, "%s/audit.log", kaihome ? kaihome : dir);
    // Real future expiry: the store's reload CLEANUP uses wall-clock time(NULL),
    // so store-test grants must not look expired against it.
    const long long FUTURE = (long long)time(NULL) + 3600;

    kai_grant_subject sub = { .pid = 100, .pidversion = 5, .agent = "claude",
                              .strength = KAI_ID_STRONG };
    char why[256];

    /* process-scoped grant: repeatable allow */
    kai_grant pg = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                           KAI_ID_STRONG, 100, 5, FUTURE);
    write_grant_file(gdir, &pg);

    /* First approval arrives after the extension opened without a key. */
    kai_approval_store *late = kai_approval_store_open(polp, gdir, NULL, 0, 0);
    CHECK(late != NULL, "policy-only store opens before first approval");
    CHECK(kai_approval_store_decide(late, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0, "no key denies signed grant");
    CHECK(kai_approval_store_install_key(late, GKEY, GKEYLEN) == 1,
          "first approval key installs on running store");
    CHECK(kai_approval_store_decide(late, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 1,
          "running store honors grant after key arrives");
    kai_approval_store_close(late);

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
                            KAI_ID_STRONG, 100, 5, FUTURE);
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
                            KAI_ID_STRONG, 100, 5, FUTURE);
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

    /* DURABILITY: a spent one-shot stays spent across a store "restart" (reopen)
     * because consumption wrote a persistent marker, not just an in-memory flag. */
    kai_approval_store *sr = kai_approval_store_open(polp, gdir, GKEY, GKEYLEN, 0);
    CHECK(kai_approval_store_decide(sr, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0,
          "spent one-shot stays spent after store restart (durable marker)");
    /* REPLAY: re-writing the same signed grant file does not resurrect it. */
    write_grant_file(gdir, &one);
    kai_approval_store_reload(sr, 1);
    CHECK(kai_approval_store_decide(sr, "/secrets/data", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0,
          "replayed consumed one-shot is rejected (marker keyed by grant id)");
    kai_approval_store_close(sr);

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

    /* AUDIT LIFECYCLE: expired and bad-signature grants are dropped AND audited
     * during the reload/cleanup pass; the drop happens regardless of audit. */
    kai_grant exp = mkgrant("/secrets/exp", KAI_OP_READ, KAI_GRANT_PROCESS,
                            KAI_ID_STRONG, 201, 5, 1 /* epoch 1 => expired */);
    write_grant_file(gdir, &exp);
    kai_grant badsig = mkgrant("/secrets/bad", KAI_OP_READ, KAI_GRANT_PROCESS,
                               KAI_ID_STRONG, 202, 5, FUTURE);
    badsig.hmac[0] = (badsig.hmac[0] == 'a') ? 'b' : 'a';  // corrupt signature
    write_grant_file(gdir, &badsig);
    kai_approval_store *sa = kai_approval_store_open(polp, gdir, GKEY, GKEYLEN, 0); // open => cleanup
    CHECK(kai_approval_store_decide(sa, "/secrets/exp", NULL, KAI_OP_READ, &sub,
                                    (long long)time(NULL), why, sizeof why) == 0, "expired grant denied");
    CHECK(kai_approval_store_decide(sa, "/secrets/bad", NULL, KAI_OP_READ, &sub,
                                    1000, why, sizeof why) == 0, "bad-signature grant denied");
    CHECK(file_contains(alog, "\"event\":\"expired\""), "expiry is audited at cleanup");
    CHECK(file_contains(alog, "\"event\":\"rejected\""), "bad signature is audited");
    // revoke audits "revoked"
    kai_grant rv = mkgrant("/secrets/rv", KAI_OP_READ, KAI_GRANT_PROCESS, KAI_ID_STRONG, 203, 5, FUTURE);
    write_grant_file(gdir, &rv);
    kai_approval_store_reload(sa, 1);
    kai_approval_store_revoke(sa, rv.id);
    CHECK(file_contains(alog, "\"event\":\"revoked\""), "revocation is audited");
    kai_approval_store_close(sa);

    /* perf: decide throughput (read-lock + match), informational */
    kai_grant pg3 = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS,
                            KAI_ID_STRONG, 100, 5, FUTURE);
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

    /* item 2: deliberate policy + grant mutation DURING concurrent decisions.
     * Invariants: no crash, and a hard-deny (control) path is NEVER granted even
     * while the policy file is being rewritten (incl. torn reads) and grants
     * churn under concurrent force-reloads. The store fails safe to last-good on
     * an unparseable policy; control detection is policy-independent. */
    kai_grant mg = mkgrant("/secrets/data", KAI_OP_READ, KAI_GRANT_PROCESS, KAI_ID_STRONG, 100, 5, FUTURE);
    write_grant_file(gdir, &mg);
    kai_approval_store *sm = kai_approval_store_open(polp, gdir, GKEY, GKEYLEN, 0);
    MUT.s = sm; snprintf(MUT.polp, sizeof MUT.polp, "%s", polp);
    snprintf(MUT.gdir, sizeof MUT.gdir, "%s", gdir); MUT.stop = 0;
    pthread_t dth[6], mth;
    pthread_create(&mth, NULL, mut_mutator, NULL);
    long ctrl = 0;
    for (int i = 0; i < 6; i++) pthread_create(&dth[i], NULL, mut_decider, NULL);
    for (int i = 0; i < 6; i++) { void *r = NULL; pthread_join(dth[i], &r); ctrl += (long)(intptr_t)r; }
    MUT.stop = 1; pthread_join(mth, NULL);
    CHECK(ctrl == 0, "hard-deny control path never granted during concurrent policy+grant mutation");
    kai_approval_store_close(sm);
    /* restore a clean policy for any later use */
    { FILE *f = fopen(polp, "w"); if (f) { fputs("protect /secrets\n", f); fclose(f); } }

    /* cleanup */
    DIR *d = opendir(gdir);
    if (d) { struct dirent *e; char fp[700];
        while ((e = readdir(d))) { if (e->d_name[0]=='.') continue;
            snprintf(fp,sizeof fp,"%s/%s",gdir,e->d_name); unlink(fp); } closedir(d); }
    unlink(alog);
    unlink(polp); rmdir(gdir); rmdir(dir);
    (void)acc;
}

static void test_denial_records(void) {
    printf("denial records (M0)\n");
    const char *kh = getenv("KAI_HOME");
    char alog[700]; snprintf(alog, sizeof alog, "%s/audit.log", kh ? kh : "/tmp");
    /* network: not-on-allowlist -> reason code in rule, host in target (#3 fix) */
    kai_denial_audit("network", "claude", "block", "innermonkeylabs.com", "connect",
                     KAI_REASON_NOT_ALLOWLISTED, NULL, "not on the allowlist");
    CHECK(file_contains(alog, "\"rule\":\"not_on_allowlist\""), "network denial: rule is a reason code");
    CHECK(file_contains(alog, "\"target\":\"innermonkeylabs.com\""), "network denial: host is in target");
    CHECK(!file_contains(alog, "\"rule\":\"innermonkeylabs.com\""),
          "network denial: host NOT mislabeled as a rule (#3 fixed)");
    /* storage: protected path -> protected_resource reason + matched rule in match */
    kai_denial_audit("storage", "codex", "block", "/tmp/x/key", "open",
                     KAI_REASON_PROTECTED, "*.pem", "agent open of a protected file");
    CHECK(file_contains(alog, "\"rule\":\"protected_resource\""), "storage denial: rule is protected_resource");
    CHECK(file_contains(alog, "\"match\":\"*.pem\""), "storage denial: matched rule recorded in match");
}

static void test_pause(void) {
    printf("safe pause (M1.7)\n");
    long long now = (long long)time(NULL);
    kai_wall_pause_write("storage", 0); kai_wall_pause_write("network", 0); /* clean start */
    CHECK(kai_wall_paused("storage", now) == 0, "not paused by default");
    kai_wall_pause_write("storage", 15);
    CHECK(kai_wall_paused("storage", now) == 1, "paused after pause-write");
    CHECK(kai_wall_paused("network", now) == 0, "other wall unaffected");
    CHECK(kai_wall_paused("storage", now + 3600) == 0, "auto-resumes after the window");
    kai_wall_pause_write("storage", 0);
    CHECK(kai_wall_paused("storage", now) == 0, "resume clears the pause");
}

static void test_policy_agent_refusal(void) {
    printf("policy change refuses agents (U0)\n");
    char dir[] = "/tmp/kai-polguardXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    char polp[600]; snprintf(polp, sizeof polp, "%s/policy", dir);
    FILE *f = fopen(polp, "w");
    if (f) { fputs("agent selftest arg *run_storage_tests*\nstorage off\n", f); fclose(f); }
    // Run `./kai policy set storage block` as a child. Its ancestor (this test,
    // argv ~ run_storage_tests) matches the agent rule, so the caller is
    // agent-attributed and the change must be refused.
    char outp[650]; snprintf(outp, sizeof outp, "%s/out", dir);
    char cmd[1400];
    snprintf(cmd, sizeof cmd,
             "KAI_HOME='%s' KAI_POLICY='%s' ./kai policy set storage block > '%s' 2>&1",
             dir, polp, outp);
    (void)system(cmd);
    CHECK(file_contains(outp, "refused"), "kai policy set refused for an agent-attributed caller");
    CHECK(file_contains(polp, "storage off") && !file_contains(polp, "storage block"),
          "policy was NOT changed by the refused agent call");
    unlink(polp); unlink(outp); rmdir(dir);
}

/* Testable dispatch (manage.c): runs a policy change with an explicit
 * caller_is_agent, so the loosen/pending/tighten logic can be exercised in
 * process even though this test itself runs under an agent. */
extern int kai_policy_dispatch(int argc, char **argv, int caller_is_agent);
extern const char *kai_policy_file(void);

/* Does any *.json under `dir` contain `needle`? */
static int pending_has(const char *dir, const char *needle) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *de; int hit = 0;
    while (!hit && (de = readdir(d))) {
        size_t nl = strlen(de->d_name);
        if (nl < 6 || strcmp(de->d_name + nl - 5, ".json")) continue;
        char p[1200]; snprintf(p, sizeof p, "%s/%s", dir, de->d_name);
        if (file_contains(p, needle)) hit = 1;
    }
    closedir(d);
    return hit;
}
static int count_json(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *de; int n = 0;
    while ((de = readdir(d))) {
        size_t nl = strlen(de->d_name);
        if (nl >= 6 && !strcmp(de->d_name + nl - 5, ".json")) n++;
    }
    closedir(d);
    return n;
}

/* U0 hardening: a change that LOOSENS protection is held pending the user's
 * confirmation regardless of caller; a TIGHTENING change applies at once;
 * every change is audited; an agent-attributed caller is refused outright. */
static void test_policy_pending(void) {
    printf("policy loosening held pending, tightening applied (U0)\n");
    char dir[] = "/tmp/kai-pendXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    /* Hermetic home for this test only; set BEFORE these calls cache paths is
     * not possible (main() already cached kai_home), so write to the real
     * cached home and a pending dir underneath it. Use KAI_POLICY-independent
     * absolute paths via kai_policy_file()/kai_home(). */
    const char *polp = kai_policy_file();
    const char *home = kai_home();
    char pend[1100]; snprintf(pend, sizeof pend, "%s/pending-policy", home);
    char alog[1100]; snprintf(alog, sizeof alog, "%s/audit.log", home);
    /* Clean slate for pending dir. */
    { char rmc[1200]; snprintf(rmc, sizeof rmc, "rm -rf '%s'", pend); (void)system(rmc); }

    FILE *f = fopen(polp, "w");
    if (f) { fputs("storage block\negress block\nsecrets redact\n", f); fclose(f); }

    /* LOOSEN: storage block -> log. Held pending; policy file unchanged. */
    char *a1[] = {"set", "storage", "log"};
    int rc1 = kai_policy_dispatch(3, a1, 0);
    CHECK(rc1 == 0, "loosen (storage block->log) returns ok (queued)");
    CHECK(file_contains(polp, "storage block") && !file_contains(polp, "storage log"),
          "loosen did NOT change the live policy");
    CHECK(pending_has(pend, "storage log"), "loosen wrote a pending request with the proposed change");

    /* TIGHTEN: secrets redact -> block. Applied immediately. */
    char *a2[] = {"set", "secrets", "block"};
    int rc2 = kai_policy_dispatch(3, a2, 0);
    CHECK(rc2 == 0, "tighten (secrets redact->block) returns ok");
    CHECK(file_contains(polp, "secrets block"), "tighten changed the live policy immediately");

    /* LOOSEN: add allow. Held pending; not in the live policy. */
    char *a3[] = {"add", "allow", "/work/x"};
    (void)kai_policy_dispatch(3, a3, 0);
    CHECK(!file_contains(polp, "allow /work/x"), "add allow did NOT change the live policy");
    CHECK(pending_has(pend, "allow /work/x"), "add allow is held pending");

    /* TIGHTEN: add protect. Applied immediately. */
    char *a4[] = {"add", "protect", "/work/z"};
    (void)kai_policy_dispatch(3, a4, 0);
    CHECK(file_contains(polp, "protect /work/z"), "add protect applied immediately");

    /* LOOSEN: remove protect. Held pending; still present in the live policy. */
    char *a5[] = {"remove", "protect", "/work/z"};
    (void)kai_policy_dispatch(3, a5, 0);
    CHECK(file_contains(polp, "protect /work/z"), "remove protect did NOT change the live policy");

    /* Audit: both a pending (loosen) and an applied (tighten) record exist,
     * each carrying the caller chain + signing identity in detail. */
    CHECK(file_contains(alog, "\"decision\":\"pending\""), "loosening change is audited as pending");
    CHECK(file_contains(alog, "\"decision\":\"applied\""), "tightening change is audited as applied");
    CHECK(file_contains(alog, "caller:"), "policy audit records the caller chain");
    CHECK(file_contains(alog, "signed:"), "policy audit records the code-signing identity");

    /* An agent-attributed caller is refused outright (first line of defense). */
    char *a6[] = {"set", "storage", "off"};
    int rc6 = kai_policy_dispatch(3, a6, 1);
    CHECK(rc6 == 3, "agent-attributed caller is refused");
    CHECK(file_contains(polp, "storage block"), "refused agent call left the policy unchanged");

    CHECK(count_json(pend) >= 3, "all loosening requests were queued (>=3)");
    rmdir(dir);
}

/* S0: the open write-classification bug that blocked Kai's own policy read.
 * ES open.fflag is in the kernel FREAD/FWRITE convention, so a read-only open
 * must NOT be classed as a write. */
static void test_open_write_classification(void) {
    printf("open read/write classification (S0)\n");
    CHECK(kai_open_is_write(FREAD) == 0, "O_RDONLY (FREAD) is a READ, not a write");
    CHECK(kai_open_is_write(FWRITE) == 1, "O_WRONLY (FWRITE) is a write");
    CHECK(kai_open_is_write(FREAD | FWRITE) == 1, "O_RDWR is a write");
    CHECK(kai_open_is_write(FREAD | O_TRUNC) == 1, "read+truncate is a write");
    CHECK(kai_open_is_write(FREAD | O_APPEND) == 1, "read+append is a write");
    CHECK(kai_open_is_write(FREAD | O_CREAT) == 1, "read+create is a write");
}

/* S0: the control store (policy, grants, pending) and the read/write rules the
 * walls apply to it. */
static void test_s0_control_store(void) {
    printf("control store identity and read/write rules (S0)\n");
    const char *home = kai_home();
    char polp[1100], grantp[1100], pendp[1100];
    snprintf(polp, sizeof polp, "%s/policy", home);
    snprintf(grantp, sizeof grantp, "%s/grants/abc.json", home);
    snprintf(pendp, sizeof pendp, "%s/pending-policy/x.json", home);
    CHECK(kai_path_is_control_store(polp) == 1, "policy file is the control store");
    CHECK(kai_path_is_control_store(grantp) == 1, "grant store is the control store");
    CHECK(kai_path_is_control_store(pendp) == 1, "pending-policy is the control store");
    CHECK(kai_path_is_control_store("/work/project/main.c") == 0, "an ordinary file is not");
    CHECK(kai_path_is_control_store("/work/.claude/settings.json") == 0,
          "a hook config is not the control store (reads are allowed for it)");

    /* The engine denies every agent-tree read AND write of the policy in block;
     * the signed-kai read exemption lives in the ES client, not here. */
    kai_policy *p = mk("storage block\n");
    char why[256] = "";
    CHECK(kai_storage_open_allowed(p, 1, 0, polp, why, sizeof why) == 0,
          "engine: agent READ of the policy is denied");
    CHECK(kai_storage_open_allowed(p, 1, 1, polp, why, sizeof why) == 0,
          "engine: agent WRITE of the policy is denied");

    /* kai_control_read_allowed: a hook config's reads may be allowed (so the
     * agent can start); Kai's own home never (it holds the policy terms). */
    why[0] = '\0';
    if (kai_path_protected(p, "/work/.claude/settings.json", NULL, why, sizeof why))
        CHECK(kai_control_read_allowed(why) == 1, "hook-config reads are allowed by the control rule");
    else
        CHECK(0, "hook config should match a builtin protect rule");
    why[0] = '\0';
    if (kai_path_protected(p, polp, NULL, why, sizeof why))
        CHECK(kai_control_read_allowed(why) == 0, "policy reads are NOT in the read-allow set");
    else
        CHECK(0, "policy should match the kai-home builtin rule");
    kai_policy_free(p);
}

/* S0: hook error behaviour when Kai can't read its own policy. The prompt hook
 * must WARN (never block the user's prompt); a tool-use hook must fail closed. */
static void test_s0_hook_errors(void) {
    printf("hook error paths when the policy is unreadable (S0)\n");
    char dir[] = "/tmp/kai-hookerrXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    char polp[600]; snprintf(polp, sizeof polp, "%s/policy", dir);
    FILE *f = fopen(polp, "w");
    if (f) { fputs("storage block\n", f); fclose(f); }
    chmod(polp, 0);   /* simulate the wall denying Kai's own policy read */

    char outp[650]; snprintf(outp, sizeof outp, "%s/out", dir);
    char cmd[1600];
    /* UserPromptSubmit: warn, not block. */
    snprintf(cmd, sizeof cmd,
             "printf '%s' | KAI_HOME='%s' KAI_POLICY='%s' ./kai hook claude > '%s' 2>/dev/null",
             "{\\\"hook_event_name\\\":\\\"UserPromptSubmit\\\",\\\"prompt\\\":\\\"hi\\\",\\\"cwd\\\":\\\"/tmp\\\"}",
             dir, polp, outp);
    (void)system(cmd);
    CHECK(!file_contains(outp, "\"decision\":\"block\""),
          "prompt hook does NOT block when Kai can't read its policy");
    CHECK(file_contains(outp, "systemMessage"),
          "prompt hook warns instead (systemMessage)");

    /* PreToolUse: fail closed (deny) with an actionable message. */
    snprintf(cmd, sizeof cmd,
             "printf '%s' | KAI_HOME='%s' KAI_POLICY='%s' ./kai hook claude > '%s' 2>/dev/null",
             "{\\\"hook_event_name\\\":\\\"PreToolUse\\\",\\\"tool_name\\\":\\\"Bash\\\","
             "\\\"tool_input\\\":{\\\"command\\\":\\\"ls\\\"},\\\"cwd\\\":\\\"/tmp\\\"}",
             dir, polp, outp);
    (void)system(cmd);
    CHECK(file_contains(outp, "\"permissionDecision\":\"deny\""),
          "tool-use hook fails closed (deny) on a policy error");

    chmod(polp, 0600); unlink(polp); unlink(outp); rmdir(dir);
}

/* S0: the dev-sandbox guard predicate. */
static void test_s0_sandbox_guard(void) {
    printf("dev-sandbox guard (S0)\n");
    /* The suite set KAI_HOME to a temp dir, so the active home is a sandbox. */
    CHECK(kai_home_is_real() == 0, "a temp KAI_HOME is recognized as a sandbox");
    /* kai_home_is_real reflects KAI_HOME live (it does not cache). Unsetting it
     * makes the predicate report the real home, which the guard would refuse.
     * Restore immediately so the rest of the suite stays hermetic. */
    char saved[1100]; const char *e = getenv("KAI_HOME");
    snprintf(saved, sizeof saved, "%s", e ? e : "");
    unsetenv("KAI_HOME");
    CHECK(kai_home_is_real() == 1, "unset KAI_HOME is refused as the real home");
    setenv("KAI_HOME", saved, 1);
}

int main(void) {
    /* Hermetic + avoids touching the real audit log: point KAI_HOME at a temp
     * dir BEFORE anything calls kai_home() (it caches on first use). */
    static char kh[] = "/tmp/kai-suite-XXXXXX";
    if (mkdtemp(kh)) setenv("KAI_HOME", kh, 1);
    /* S0 rule: never run against the real Kai home. */
    kai_require_sandbox_home();
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
    test_denial_records();
    test_pause();
    test_policy_agent_refusal();
    test_policy_pending();
    test_open_write_classification();
    test_s0_control_store();
    test_s0_hook_errors();
    test_s0_sandbox_guard();

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "all passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
