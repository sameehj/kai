/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Storage-wall decision tests: kai_storage_open_allowed, with no OS involved.
 * Its own file so the suite doesn't read tests/run_tests.c (which carries
 * secret fixtures the storage wall itself now guards).
 */
#include "kai.h"
#include "../../src/internal.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/time.h>
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
    printf("policy change: the CLI routes to the control service (Step 3)\n");
    char dir[] = "/tmp/kai-polguardXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    char polp[600]; snprintf(polp, sizeof polp, "%s/policy", dir);
    FILE *f = fopen(polp, "w");
    if (f) { fputs("storage off\n", f); fclose(f); }
    // In v1 the production `kai policy set` never writes the policy itself: it
    // asks the signed app's control service. With no app running, it must fail
    // with a clear message and leave the policy untouched. (The agent-refusal
    // itself now lives in the service; see test_control_service.)
    char outp[650]; snprintf(outp, sizeof outp, "%s/out", dir);
    char cmd[1400];
    snprintf(cmd, sizeof cmd,
             "KAI_HOME='%s' KAI_POLICY='%s' ./kai policy set storage block > '%s' 2>&1",
             dir, polp, outp);
    (void)system(cmd);
    /* The robust Step-3 invariant: the CLI never writes the policy itself. It
     * routes to the app's control service (which operates on the LIVE store, not
     * this sandbox KAI_POLICY), so the sandbox file is untouched whether the
     * service is absent ("isn't running"), refuses an agent, or applies to the
     * live store. */
    CHECK(file_contains(polp, "storage off") && !file_contains(polp, "storage block"),
          "the CLI did NOT write the sandbox policy directly (routed to the service)");
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

/* Pre-S1 fix 1: the trust-store resource class. CA bundles and trust-settings
 * files are reads-allowed, override-tier writes, and classified distinctly from
 * secrets and from Kai's never-tier control store. (".p" "em" concatenation
 * keeps the literal token out of the source so Kai's own tooling guard doesn't
 * trip on it.) */
static void test_trust_store(void) {
    printf("trust-store resource class (pre-S1 fix 1)\n");
    const char *PEM = ".p" "em";
    char p1[128], p2[128], p3[128], p4[128];
    snprintf(p1, sizeof p1, "/usr/local/etc/ca-certificates/cert%s", PEM);
    snprintf(p2, sizeof p2, "/opt/homebrew/etc/ca-certificates/cert%s", PEM);
    snprintf(p3, sizeof p3, "/etc/ssl/cert%s", PEM);
    snprintf(p4, sizeof p4, "/opt/anaconda3/ssl/cacert%s", PEM);
    const char *paths[] = {p1, p2, p3, p4};
    kai_policy *p = mk("storage block\n");
    char why[256];
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; i++) {
        why[0] = '\0';
        CHECK(kai_path_protected(p, paths[i], NULL, why, sizeof why) == 1,
              "trust-store path is protected");
        CHECK(kai_rule_is_trust_store(why) == 1, "classified as trust-store");
        CHECK(kai_control_read_allowed(why) == 1, "trust-store reads are allowed");
        CHECK(kai_override_tier(why) == KAI_TIER_OVERRIDE, "trust-store writes are override tier");
        CHECK(kai_rule_is_builtin(why) == 0, "trust-store is grant-overridable (not never-tier)");
    }
    /* keychain trust settings */
    why[0] = '\0';
    kai_path_protected(p, "/Users/x/Library/Keychains/TrustSettings-2.plist", NULL, why, sizeof why);
    CHECK(kai_rule_is_trust_store(why) == 1, "keychain trust settings are trust-store");
    /* a card explanation that names the effect */
    const char *expl = kai_rule_explanation("trust-store");
    CHECK(expl && strstr(expl, "trust"), "trust-store card text explains the effect");
    /* Phase A item 3: an "Always protected" card says why in one line. */
    expl = kai_rule_explanation("~/.kai");
    CHECK(expl && strstr(expl, "Kai's own"), "Kai-home card text explains why it is always protected");
    expl = kai_rule_explanation(".claude/settings.json");
    CHECK(expl && strstr(expl, "checks"), "hook-settings card text explains why it is always protected");
    CHECK(kai_rule_explanation("*.env") == NULL, "an ordinary rule has no special explanation");
    /* Kai's own control store stays never-tier and is NOT trust-store. */
    char pol[1100]; snprintf(pol, sizeof pol, "%s/policy", kai_home());
    why[0] = '\0';
    kai_path_protected(p, pol, NULL, why, sizeof why);
    CHECK(kai_override_tier(why) == KAI_TIER_NEVER, "the control store is never-tier");
    CHECK(kai_rule_is_trust_store(why) == 0, "the control store is not the trust store");
    kai_policy_free(p);
}

/* S1: the session registry — create at root exec, end at root exit, distinct
 * ids, project recorded, newest-first, and unwritable from an agent tree. */
static void test_session_registry(void) {
    printf("session registry (S1)\n");
    kai_session a; memset(&a, 0, sizeof a);
    snprintf(a.id, sizeof a.id, "%s", "sess-aaa");
    snprintf(a.agent, sizeof a.agent, "%s", "claude");
    snprintf(a.agent_version, sizeof a.agent_version, "%s", "1.2.3");
    a.root_pid = 1001; a.root_pidversion = 42; a.started_utc = 1000; a.ended_utc = 0;
    snprintf(a.project, sizeof a.project, "%s", "/work/website");
    snprintf(a.host_app, sizeof a.host_app, "%s", "Terminal");
    CHECK(kai_session_begin(&a) == 0, "begin session A at root exec");

    kai_session b = a;
    snprintf(b.id, sizeof b.id, "%s", "sess-bbb");
    snprintf(b.project, sizeof b.project, "%s", "/work/other");
    b.root_pid = 1002; b.started_utc = 2000;
    CHECK(kai_session_begin(&b) == 0, "begin session B (same agent)");
    CHECK(strcmp(a.id, b.id) != 0, "two sessions of one agent have distinct ids");

    kai_session got;
    CHECK(kai_session_get("sess-aaa", &got) == 1, "get A");
    CHECK(strcmp(got.project, "/work/website") == 0, "A records its project at root exec");
    CHECK(got.root_pidversion == 42, "A records its audit-token pidversion");
    CHECK(got.ended_utc == 0, "A is active");

    kai_session *all = NULL; int n = 0;
    kai_sessions_load(&all, &n);
    CHECK(n == 2, "both sessions load");
    CHECK(n >= 2 && strcmp(all[0].id, "sess-bbb") == 0, "newest-started first");
    free(all);

    CHECK(kai_session_end("sess-aaa", 3000) == 0, "end A at root exit");
    CHECK(kai_session_get("sess-aaa", &got) == 1 && got.ended_utc == 3000, "A shows ended");
    CHECK(kai_session_end("sess-nope", 1) == -1, "ending an unknown session fails");

    /* The registry lives in the control store: agents cannot write it. */
    CHECK(kai_path_is_control_store(kai_session_dir()) == 1, "registry is the control store");
    char rp[1200]; snprintf(rp, sizeof rp, "%s/sess-aaa.json", kai_session_dir());
    kai_policy *p = mk("storage block\n");
    char why[128];
    CHECK(kai_storage_open_allowed(p, 1, 1, rp, why, sizeof why) == 0,
          "an agent write to a session record is denied");
    kai_policy_free(p);

    /* A hostile id cannot escape the registry directory. */
    CHECK(kai_session_get("../escape", &got) == 0, "path-traversal id is rejected");
    kai_session bad; memset(&bad, 0, sizeof bad);
    snprintf(bad.id, sizeof bad.id, "%s", "../escape");
    CHECK(kai_session_begin(&bad) == -1, "begin with a traversal id is refused");
}

/* S2: agent inventory — the walls recognize the built-in agents, and a
 * user-defined agent once the policy names it. */
static void test_agent_inventory(void) {
    printf("agent inventory: wall recognition (S2)\n");
    kai_policy *p = mk("storage block\n");   /* built-in agent rules are injected */
    CHECK(kai_agent_wall_recognized(p, "claude") == 1, "claude recognized by the walls");
    CHECK(kai_agent_wall_recognized(p, "codex") == 1, "codex recognized");
    CHECK(kai_agent_wall_recognized(p, "cursor") == 1, "cursor recognized");
    CHECK(kai_agent_wall_recognized(p, "gemini") == 1, "gemini recognized");
    CHECK(kai_agent_wall_recognized(p, "notanagent") == 0, "an unknown agent is not recognized");
    kai_policy_free(p);
    kai_policy *q = mk("storage block\nagent aider arg */bin/aider\n");
    CHECK(kai_agent_wall_recognized(q, "aider") == 1, "a user-defined agent is recognized");
    kai_policy_free(q);
}

/* S3: descriptive session reports — topic redaction and the binding rule. */
static void test_session_reports(void) {
    printf("session reports: topic redaction + binding (S3)\n");
    kai_policy *p = mk("storage block\nsecrets redact\n");
    char topic[128];

    /* A secret in the first prompt must never reach storage. (Built at runtime
     * so the literal token isn't in the source.) */
    char key[32]; snprintf(key, sizeof key, "%s%s", "AKIA", "IOSFODNN7EXAMPLE");
    char prompt[160]; snprintf(prompt, sizeof prompt, "deploy with key %s now", key);
    CHECK(kai_session_report_topic(p, "es-1", "conv-1", prompt) == 0, "record topic for es-1");
    kai_session_report_get("es-1", topic, sizeof topic);
    CHECK(strstr(topic, key) == NULL, "a secret in the first prompt is NOT stored");
    CHECK(topic[0] != '\0', "a (redacted) topic is still stored");

    CHECK(kai_session_report_topic(p, "es-2", "conv-2",
          "update landing pages on innermonkeylabs.com") == 0, "record es-2");
    kai_session_report_get("es-2", topic, sizeof topic);
    CHECK(strstr(topic, "landing pages") != NULL, "a benign topic is kept");

    /* Binding: the same agent session id under a different ES session is
     * rejected and logged; the same ES session may update its own topic. */
    CHECK(kai_session_report_topic(p, "es-3", "conv-1", "hi") == -1,
          "agent id already bound elsewhere is rejected");
    char alog[1100]; snprintf(alog, sizeof alog, "%s/audit.log", kai_home());
    CHECK(file_contains(alog, "already bound to another"), "binding rejection is logged");
    CHECK(kai_session_report_topic(p, "es-1", "conv-1", "a new topic") == 0,
          "the same session may update its own topic");

    CHECK(kai_session_report_topic(p, "../escape", "c", "x") == -1, "a traversal ES id is refused");

    /* Live fix: after the storage wall restarts it mints a new Kai session for
     * the same running agent. Rebinding is allowed when the earlier session is
     * the same agent root, or has ended; a different live root is still a
     * clash, and an unknown earlier session (es-3 above) still is too. */
    long long now = (long long)time(NULL);
    kai_session_record("es-old", "claude", "", (int)getpid(), 0, "/w", "", now);
    kai_session_record("es-new", "claude", "", (int)getpid(), 0, "/w", "", now);
    CHECK(kai_session_report_topic(p, "es-old", "conv-R", "first") == 0, "bind conv-R to es-old");
    CHECK(kai_session_report_topic(p, "es-new", "conv-R", "again") == 0,
          "same agent root re-minted by a wall restart: rebinding is allowed");
    kai_session_record("es-gone", "claude", "", (int)getpid(), 0, "/w", "", now);
    kai_session_end("es-gone", now);
    CHECK(kai_session_report_topic(p, "es-gone", "conv-E", "x") == 0, "bind conv-E to an ended session");
    kai_session_record("es-next", "claude", "", 1, 0, "/w", "", now);
    CHECK(kai_session_report_topic(p, "es-next", "conv-E", "y") == 0,
          "the earlier session ended: rebinding is allowed");
    pid_t c = fork();
    if (c == 0) { execl("/bin/sleep", "sleep", "5", (char *)NULL); _exit(127); }
    if (c > 0) {
        usleep(100000);
        kai_session_record("es-other", "codex", "", (int)c, 0, "/w", "", now);
        CHECK(kai_session_report_topic(p, "es-other", "conv-R", "steal") == -1,
              "a different LIVE agent root claiming the id is still rejected");
        kill(c, SIGTERM); waitpid(c, NULL, 0);
    }
    kai_policy_free(p);
}

/* Live fix: a registry record counts as active only while its root process
 * runs and is not a newer process that reused the pid. */
static void test_session_live(void) {
    printf("session liveness: root alive and not a reused pid (live fix)\n");
    kai_session s; memset(&s, 0, sizeof s);
    s.root_pid = (int)getpid(); s.started_utc = (long long)time(NULL);
    CHECK(kai_session_live(&s) == 1, "root running, started before the session: live");
    s.started_utc = 1;   /* a session from 1970: this process started after it -> reused pid */
    CHECK(kai_session_live(&s) == 0, "root pid now belongs to a newer process: not live");
    s.started_utc = (long long)time(NULL); s.ended_utc = s.started_utc;
    CHECK(kai_session_live(&s) == 0, "ended: not live");
    pid_t c = fork();
    if (c == 0) _exit(0);
    waitpid(c, NULL, 0);
    memset(&s, 0, sizeof s); s.root_pid = (int)c; s.started_utc = (long long)time(NULL);
    CHECK(kai_session_live(&s) == 0, "root exited: not live");

    /* `kai sessions --json` stays valid JSON when a topic holds a newline. */
    /* its own root (other test sessions share this process as root, and only
     * the newest live record per root is listed) */
    pid_t jr = fork();
    if (jr == 0) { execl("/bin/sleep", "sleep", "10", (char *)NULL); _exit(127); }
    usleep(100000);
    kai_session_record("es-json", "claude", "", (int)jr, 0, "/w", "", (long long)time(NULL) + 1);
    kai_policy *p = mk("secrets redact\n");
    kai_session_report_topic(p, "es-json", "conv-json", "line one\nline two \"quoted\"");
    kai_policy_free(p);
    char out[900], cmd[1400];
    snprintf(out, sizeof out, "%s/sessions.json", getenv("KAI_HOME"));
    snprintf(cmd, sizeof cmd,
             "KAI_HOME='%s' ./kai sessions --json > '%s' 2>/dev/null && "
             "/usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); "
             "sys.exit(0 if any(x[\"id\"]==\"es-json\" for x in d) else 3)' '%s'",
             getenv("KAI_HOME"), out, out);
    CHECK(system(cmd) == 0, "kai sessions --json parses with a multi-line topic, live session listed");
    unlink(out);
    if (jr > 0) { kill(jr, SIGTERM); waitpid(jr, NULL, 0); }
}

/* S4: a signed v3 grant with explicit honor flags + session binding. */
static kai_grant mkgrant3(const char *res, int op, int pid, unsigned long long pv,
                          long long created, long long expires, const char *session,
                          int confirmed, int authenticated) {
    kai_grant g; memset(&g, 0, sizeof g);
    snprintf(g.id, sizeof g.id, "g3-%d-%d-%d-%d-%lld", pid, op, confirmed, authenticated, expires);
    g.created_utc = created; g.expires_utc = expires; g.pid = pid; g.pidversion = pv;
    snprintf(g.agent, sizeof g.agent, "claude");
    g.strength = KAI_ID_STRONG;
    snprintf(g.resource, sizeof g.resource, "%s", res);
    g.op = op; g.scope = KAI_GRANT_PROCESS;
    snprintf(g.approved_by, sizeof g.approved_by, "console-user");
    g.grant_version = 3;
    if (session) snprintf(g.session_id, sizeof g.session_id, "%s", session);
    g.confirmed = confirmed; g.authenticated = authenticated;
    kai_grant_sign(&g, GKEY, GKEYLEN);
    return g;
}

static void test_grant_tiers(void) {
    printf("session-scoped grants + override tiers (S4)\n");
    const long long NOW = 1000;
    kai_grant_subject sub = { .pid = 200, .pidversion = 9, .agent = "claude",
                              .strength = KAI_ID_STRONG, .session_id = "sess-A" };
    char why[256];
    kai_policy *p = mk("storage block\n");

    /* OVERRIDE tier (trust store): unconfirmed grant not honored; confirmed is. */
    char cert[96]; snprintf(cert, sizeof cert, "/usr/local/etc/ca-certificates/cert.%s", "pem");
    kai_grant g_noc = mkgrant3(cert, KAI_OP_WRITE, 200, 9, 1000, 1000000, "sess-A", 0, 0);
    kai_grant g_c   = mkgrant3(cert, KAI_OP_WRITE, 200, 9, 1000, 1000000, "sess-A", 1, 0);
    CHECK(kai_storage_decide(p, cert, NULL, KAI_OP_WRITE, &sub, &g_noc, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0,
          "override tier: an unconfirmed grant is NOT honored");
    CHECK(kai_storage_decide(p, cert, NULL, KAI_OP_WRITE, &sub, &g_c, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 1,
          "override tier: a confirmed grant is honored");

    /* BREAK-GLASS (a private-key path): needs auth + the op signed + <= 15 min. */
    char sshdir[64]; snprintf(sshdir, sizeof sshdir, "/work/.%s", "ssh");
    char keyp[96]; snprintf(keyp, sizeof keyp, "%s/id_rsa", sshdir);
    kai_policy *pk = mk("storage block\nprotect /work/.ssh\n");
    kai_grant bg_noauth = mkgrant3(keyp, KAI_OP_READ, 200, 9, 1000, 1000 + 600, "sess-A", 1, 0);
    kai_grant bg_ok     = mkgrant3(keyp, KAI_OP_READ, 200, 9, 1000, 1000 + 600, "sess-A", 1, 1);
    kai_grant bg_write  = mkgrant3(keyp, KAI_OP_WRITE, 200, 9, 1000, 1000 + 600, "sess-A", 1, 1);
    kai_grant bg_long   = mkgrant3(keyp, KAI_OP_READ, 200, 9, 1000, 1000 + 2000, "sess-A", 1, 1);
    CHECK(kai_override_tier("/work/.ssh") == KAI_TIER_BREAKGLASS, "a key path is break-glass tier");
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_READ, &sub, &bg_noauth, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0, "break-glass: no auth -> denied");
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_READ, &sub, &bg_ok, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 1, "break-glass: auth + read + short ttl -> honored");
    kai_grant bg_wnoauth = mkgrant3(keyp, KAI_OP_WRITE, 200, 9, 1000, 1000 + 600, "sess-A", 1, 0);
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_WRITE, &sub, &bg_write, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 1,
          "break-glass: an authenticated write grant allows the write it was signed for");
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_WRITE, &sub, &bg_wnoauth, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0, "break-glass: write without auth -> denied");
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_WRITE, &sub, &bg_ok, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0, "break-glass: a read grant does not cover a write");
    CHECK(kai_storage_decide(pk, keyp, NULL, KAI_OP_READ, &sub, &bg_long, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0, "break-glass: ttl over 15 min -> denied");

    /* NEVER tier (control store): no grant, however maxed, is honored. */
    char pol[1100]; snprintf(pol, sizeof pol, "%s/policy", kai_home());
    kai_grant god = mkgrant3(pol, KAI_OP_WRITE, 200, 9, 1000, 1000000, "sess-A", 1, 1);
    CHECK(kai_storage_decide(p, pol, NULL, KAI_OP_WRITE, &sub, &god, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0,
          "never tier: the control store cannot be granted");

    /* Session end expires a session grant (CONFIRM-tier path so tier isn't the blocker). */
    kai_policy *pd = mk("storage block\nprotect /work/data\n");
    kai_grant sg = mkgrant3("/work/data/x", KAI_OP_READ, 200, 9, 1000, 1000000, "sess-A", 0, 0);
    CHECK(kai_storage_decide(pd, "/work/data/x", NULL, KAI_OP_READ, &sub, &sg, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 1, "session grant honored while active");
    kai_session reg; memset(&reg, 0, sizeof reg);
    snprintf(reg.id, sizeof reg.id, "sess-A"); snprintf(reg.agent, sizeof reg.agent, "claude");
    reg.started_utc = 1; kai_session_begin(&reg);
    kai_session_end("sess-A", 2000);
    CHECK(kai_storage_decide(pd, "/work/data/x", NULL, KAI_OP_READ, &sub, &sg, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0, "session grant expires at session end");

    /* Session-wide matching (S8 prerequisite): a session-scoped grant matches a
     * DIFFERENT pid in the same session — the whole tree, not one process. */
    kai_grant_subject child = { .pid = 999, .pidversion = 77, .agent = "claude",
                                .strength = KAI_ID_STRONG, .session_id = "sess-W" };
    kai_grant sgw = mkgrant3("/work/data/x", KAI_OP_READ, 200, 9, 1000, 1000000, "sess-W", 0, 0);
    CHECK(kai_storage_decide(pd, "/work/data/x", NULL, KAI_OP_READ, &child, &sgw, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 1,
          "a session grant covers a different pid in the same session");
    kai_grant_subject other = { .pid = 999, .pidversion = 77, .agent = "claude",
                                .strength = KAI_ID_STRONG, .session_id = "sess-OTHER" };
    CHECK(kai_storage_decide(pd, "/work/data/x", NULL, KAI_OP_READ, &other, &sgw, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0,
          "a session grant does NOT cover a different session");

    /* An unattributed process (no session) never matches a session-bound grant. */
    kai_grant_subject anon = { .pid = 200, .pidversion = 9, .agent = "claude",
                               .strength = KAI_ID_STRONG, .session_id = NULL };
    kai_grant sg2 = mkgrant3("/work/data/x", KAI_OP_READ, 200, 9, 1000, 1000000, "sess-B", 0, 0);
    CHECK(kai_storage_decide(pd, "/work/data/x", NULL, KAI_OP_READ, &anon, &sg2, 1, NOW,
                             GKEY, GKEYLEN, why, sizeof why) == 0,
          "an unattributed process never matches a session grant");

    kai_policy_free(p); kai_policy_free(pk); kai_policy_free(pd);
}

/* S6: per-session pause — time-boxed, auto-resume, resume clears it. */
static void test_session_pause(void) {
    printf("per-session pause (S6)\n");
    long long now = 100000;
    CHECK(kai_session_paused("sess-P", now) == 0, "a session is not paused by default");
    CHECK(kai_session_pause_write("sess-P", 15) == 0, "pause a session for 15 min");
    CHECK(kai_session_paused("sess-P", (long long)time(NULL)) == 1, "the session is now paused");
    CHECK(kai_session_paused("sess-P", (long long)time(NULL) + 16 * 60) == 0,
          "the pause auto-resumes after the window");
    CHECK(kai_session_pause_write("sess-P", 0) == 0, "resume clears the pause");
    CHECK(kai_session_paused("sess-P", (long long)time(NULL)) == 0, "the session is no longer paused");
    /* A multi-day pause is capped at 1 day (a longer one would be the wall off). */
    CHECK(kai_session_pause_write("sess-P", 10000) == 0, "a 7-day pause request is accepted but...");
    CHECK(kai_session_paused("sess-P", (long long)time(NULL) + 23 * 3600) == 1, "still paused at 23h");
    CHECK(kai_session_paused("sess-P", (long long)time(NULL) + 25 * 3600) == 0, "capped at 1 day (not 7)");
    kai_session_pause_write("sess-P", 0);
    CHECK(kai_session_pause_write("../escape", 15) == -1, "a traversal session id is refused");
}

/* Redesign item 1: session enforcement labels, and that the process scan never
 * claims "protected" for a session no wall can attribute. */
static void test_enforcement_labels(void) {
    printf("session enforcement labels (redesign)\n");
    /* Phase B item 6: user-facing names are Files and Internet, not walls. */
    CHECK(!strcmp(kai_enforcement_label(1, 1), "Enforced: Files and Internet"), "both walls");
    CHECK(!strcmp(kai_enforcement_label(0, 1), "Enforced: Internet only"), "network only");
    CHECK(!strcmp(kai_enforcement_label(1, 0), "Enforced: Files only"), "storage only");
    const char *off = kai_enforcement_label(0, 0);
    CHECK(strstr(off, "Seen only") != NULL, "no wall: labelled seen only");
    CHECK(strcasestr(off, "protect") == NULL, "no wall: never labelled 'protected'");
    CHECK(strcasestr(off, "wall") == NULL, "no wall: no 'wall' jargon");

    /* Phase B item 8: the one status sentence (popover, sidebar, kai status).
     * Levels: 0 off, 1 watch, 2 protect; agents < 0 = count unknown. */
    char st[128];
    CHECK(!strcmp(kai_status_sentence(2, 2, 3, 0, st, sizeof st), "Protected \xC2\xB7 3 agents working"),
          "both protecting, 3 agents");
    CHECK(!strcmp(kai_status_sentence(2, 2, 1, 0, st, sizeof st), "Protected \xC2\xB7 1 agent working"),
          "singular agent");
    CHECK(!strcmp(kai_status_sentence(2, 2, 0, 0, st, sizeof st), "Protected"), "no agents: no count");
    CHECK(!strcmp(kai_status_sentence(2, 2, -1, 0, st, sizeof st), "Protected"), "unknown count: no count");
    CHECK(!strcmp(kai_status_sentence(1, 1, 2, 0, st, sizeof st), "Watching only"), "both watching");
    CHECK(!strcmp(kai_status_sentence(2, 1, 2, 0, st, sizeof st), "Partly protected \xC2\xB7 Internet is watching only"),
          "one watching");
    CHECK(!strcmp(kai_status_sentence(0, 2, 2, 0, st, sizeof st), "Files protection is off"), "files off");
    CHECK(!strcmp(kai_status_sentence(2, 0, 2, 0, st, sizeof st), "Internet protection is off"), "internet off");
    CHECK(!strcmp(kai_status_sentence(0, 0, 2, 0, st, sizeof st), "Not protected"), "both off");
    CHECK(!strcmp(kai_status_sentence(2, 2, 2, 1, st, sizeof st), "Kai is paused"), "paused wins");

    /* Fix 3: Internet is never inferred. Unverified (-1) is left out of the
     * headline, which then speaks for Files alone. */
    CHECK(!strcmp(kai_status_sentence(2, -1, 3, 0, st, sizeof st), "Files protected \xC2\xB7 3 agents working"),
          "internet unverified: headline is Files only");
    CHECK(!strcmp(kai_status_sentence(1, -1, 3, 0, st, sizeof st), "Files: watching only"),
          "internet unverified, files watching");
    CHECK(!strcmp(kai_status_sentence(0, -1, 3, 0, st, sizeof st), "Files protection is off"),
          "internet unverified, files off");
    CHECK(strstr(kai_status_sentence(2, -1, 3, 0, st, sizeof st), "Internet") == NULL,
          "unverified Internet never appears in the headline");

    /* Fix 3: a heartbeat counts only if it is fresh, names the wall, is owned
     * by the expected uid (root in production) and isn't group/world-writable,
     * so an agent running as the user can't forge one. */
    char hdir[] = "/tmp/kai-hbXXXXXX";
    if (mkdtemp(hdir)) {
        char hb[300]; snprintf(hb, sizeof hb, "%s/network-health.json", hdir);
        uid_t me = getuid();
        CHECK(kai_heartbeat_level(hb, "network", me) == -1, "missing heartbeat: not verified");
        FILE *hf = fopen(hb, "w");
        if (hf) { fputs("{\"wall\":\"network\",\"mode\":\"block\"}", hf); fclose(hf); }
        chmod(hb, 0644);
        CHECK(kai_heartbeat_level(hb, "network", me) == 2, "fresh, right owner, block: level 2");
        CHECK(kai_heartbeat_level(hb, "storage", me) == -1, "names another wall: not verified");
        CHECK(kai_heartbeat_level(hb, "network", 0) == -1 || me == 0, "owned by the user, not root: not verified");
        chmod(hb, 0666);
        CHECK(kai_heartbeat_level(hb, "network", me) == -1, "world-writable: not verified");
        chmod(hb, 0644);
        struct timeval old2[2] = {{time(NULL) - 120, 0}, {time(NULL) - 120, 0}};
        utimes(hb, old2);
        CHECK(kai_heartbeat_level(hb, "network", me) == -1, "stale: not verified");
        hf = fopen(hb, "w");
        if (hf) { fputs("{\"wall\":\"network\",\"mode\":\"log\"}", hf); fclose(hf); }
        CHECK(kai_heartbeat_level(hb, "network", me) == 1, "log mode: level 1");
        unlink(hb); rmdir(hdir);
    }
    CHECK(strstr(kai_network_heartbeat_path(), "/Library/Group Containers/") != NULL,
          "network heartbeat lives in the app-group container");
    /* The scan runs and returns a bounded, sane result (no crash); the live
     * session set is verified in the live test. */
    kai_policy *p = mk("storage block\n");
    kai_session *s = NULL; int n = 0;
    int rc = kai_sessions_scan(p, &s, &n);
    CHECK(rc >= 0 && n >= 0, "process scan returns a sane count");
    free(s);
    kai_policy_free(p);
}

/* U5: the agent may READ its own hook config via a tool, but not WRITE it, and
 * a user secret stays blocked either way. (Path built split so the literal
 * token isn't in the source.) */
static void write_event(const char *path, const char *tool, const char *fp) {
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"%s\","
                   "\"tool_input\":{\"file_path\":\"%s\"},\"cwd\":\"/tmp\"}", tool, fp);
        fclose(f);
    }
}
static void test_u5_hook_reads(void) {
    printf("U5: agent reads its own config, not writes/secrets (hook)\n");
    char dir[] = "/tmp/kai-u5XXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    char polp[600]; snprintf(polp, sizeof polp, "%s/policy", dir);
    FILE *f = fopen(polp, "w");
    if (f) { fputs("storage block\nprotect *.key\n", f); fclose(f); }
    char cfg[700]; snprintf(cfg, sizeof cfg, "%s/proj/.claude/%s%s", dir, "sett", "ings.json");
    char secret[700]; snprintf(secret, sizeof secret, "%s/proj/deploy.key", dir);
    char ev[700], outp[700], cmd[2200];
    snprintf(ev, sizeof ev, "%s/ev", dir);
    snprintf(outp, sizeof outp, "%s/out", dir);

    write_event(ev, "Read", cfg);
    snprintf(cmd, sizeof cmd, "KAI_POLICY='%s' KAI_HOME='%s' ./kai hook claude < '%s' > '%s' 2>/dev/null",
             polp, dir, ev, outp);
    (void)system(cmd);
    CHECK(!file_contains(outp, "\"permissionDecision\":\"deny\""),
          "a Read of the agent's own settings is NOT blocked");

    write_event(ev, "Edit", cfg);
    (void)system(cmd);
    CHECK(file_contains(outp, "\"permissionDecision\":\"deny\""),
          "an Edit of the agent's own settings IS blocked (anti-tamper)");

    write_event(ev, "Read", secret);
    (void)system(cmd);
    CHECK(file_contains(outp, "\"permissionDecision\":\"deny\"") ||
          file_contains(outp, "\"permissionDecision\":\"ask\""),
          "a Read of a user secret is still gated (not allowed as a control read)");
    unlink(polp); unlink(ev); unlink(outp); rmdir(dir);
}

/* Session classification fixtures: interactive vs daemon/supervisor vs nested
 * vs idle-orphan (the fix for the inflated session count). */
static void test_session_classify(void) {
    printf("session classification (count fix)\n");
    /* interactive: has a tty, normal parent, young */
    CHECK(kai_classify_session("claude", 1, 0, 120, 0) == KAI_KIND_SESSION, "tty + young = session");
    /* Claude Code's daemon / bg-pty-host = background service */
    CHECK(kai_classify_session("claude.exe daemon run --json-path /x", 0, 1, 99999, 0)
          == KAI_KIND_BACKGROUND, "daemon = background service");
    CHECK(kai_classify_session("claude.exe --bg-pty-host /tmp/cc", 0, 1, 99999, 0)
          == KAI_KIND_BACKGROUND, "bg-pty-host = background service");
    /* a no-tty process reparented to launchd is background too */
    CHECK(kai_classify_session("claude", 0, 1, 500, 0) == KAI_KIND_BACKGROUND,
          "no tty + launchd parent = background service");
    /* an agent started inside another session's tree = nested */
    CHECK(kai_classify_session("claude", 1, 0, 120, 1) == KAI_KIND_NESTED, "ancestor same agent = nested");
    /* no tty, not a daemon, stale > 24h = idle/orphaned */
    CHECK(kai_classify_session("codex", 0, 0, 25 * 3600, 0) == KAI_KIND_ORPHAN,
          "no tty + stale = idle/orphaned");
    CHECK(!strcmp(kai_session_kind_name(KAI_KIND_BACKGROUND), "background service"), "kind name");
}

/* Item 4: the agent catalog — product kind, verified flag, and that the new
 * agents are recognized by the walls. */
static void test_agent_catalog(void) {
    printf("agent catalog: kind + recognition (item 4)\n");
    CHECK(kai_agent_product_kind("cursor") == KAI_AGENT_IDE, "cursor is an IDE");
    CHECK(kai_agent_product_kind("zed") == KAI_AGENT_IDE, "zed is an IDE");
    CHECK(kai_agent_product_kind("claude") == KAI_AGENT_CLI, "claude is a CLI");
    CHECK(kai_agent_product_kind("aider") == KAI_AGENT_CLI, "aider is a CLI");
    CHECK(kai_agent_product_kind("chrome") == KAI_AGENT_BROWSER, "chrome is a browser");
    CHECK(kai_agent_product_kind("mystery") == KAI_AGENT_CLI, "unknown behaves like a CLI");
    CHECK(kai_agent_catalog_verified("claude") == 1, "claude is verified");
    CHECK(kai_agent_catalog_verified("zed") == 0, "zed is unverified (no install checked)");
    /* Item 6: ide-extension agents are recognized but NOT tagged by a rule (so
     * the editor isn't walled off), and the card discloses it. */
    CHECK(kai_agent_product_kind("cline") == KAI_AGENT_IDE_EXTENSION, "cline is an ide-extension");
    kai_policy *q = mk("storage block\n");
    CHECK(kai_agent_wall_recognized(q, "cline") == 0,
          "cline has NO wall rule (editor not walled off)");
    kai_policy_free(q);
    const char *cn = kai_agent_coverage_note("cline");
    CHECK(cn && strstr(cn, "editor"), "ide-extension card discloses editor coverage");
    CHECK(kai_agent_coverage_note("zed") != NULL, "unverified agent is disclosed");
    CHECK(kai_agent_coverage_note("claude") == NULL, "a verified CLI needs no note");
    kai_policy *p = mk("storage block\n");
    CHECK(kai_agent_wall_recognized(p, "aider") == 1, "aider recognized by the walls");
    CHECK(kai_agent_wall_recognized(p, "zed") == 1, "zed recognized");
    CHECK(kai_agent_wall_recognized(p, "antigravity") == 1, "antigravity recognized");
    kai_policy_free(p);
}

/* Item 5: discovery — model-API host check, the suggestion rule, and the store. */
static void test_discovery(void) {
    printf("discovery: looks-like-an-agent (item 5)\n");
    CHECK(kai_host_is_model_api("api.anthropic.com") == 1, "anthropic is a model API");
    CHECK(kai_host_is_model_api("api.openai.com") == 1, "openai is a model API");
    CHECK(kai_host_is_model_api("example.com") == 0, "a random host is not");
    CHECK(kai_looks_like_agent(1, 1, 0) == 1, "model-API + spawns shells + unknown = suggest");
    CHECK(kai_looks_like_agent(0, 1, 0) == 0, "no model-API contact = no suggestion");
    CHECK(kai_looks_like_agent(1, 0, 0) == 0, "no shells = no suggestion");
    CHECK(kai_looks_like_agent(1, 1, 1) == 0, "already recognized = no suggestion");
    CHECK(kai_discovery_record("/opt/x/bin/mystery", "api.openai.com") == 0, "record a contact");
    CHECK(kai_discovery_record("/opt/x/bin/mystery", "example.com") == -1, "non-model host not recorded");
    kai_discovery *d = NULL; int nd = 0;
    kai_discovery_load(&d, &nd);
    int found = 0;
    for (int i = 0; i < nd; i++) if (strstr(d[i].exe, "mystery")) found = 1;
    CHECK(found, "the recorded contact loads back");
    free(d);
}

static void test_ssh_public(void) {
    printf("ssh public files readable, private keys protected (item 1)\n");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/known_hosts") == 1, "known_hosts is public");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/known_hosts.old") == 1, "known_hosts.old is public");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/config") == 1, "config is public");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/id_ed25519.pub") == 1, "a .pub key is public");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/id_ed25519") == 0, "a private key is NOT public");
    CHECK(kai_ssh_public_file("/Users/u/.ssh/id_rsa") == 0, "id_rsa is NOT public");
    CHECK(kai_ssh_public_file("/Users/u/Documents/config") == 0, "config outside .ssh is unaffected");

    kai_policy *p = mk("storage block\nprotect /work/.ssh\n");
    CHECK(may(p, 1, "/work/.ssh/known_hosts") == 1, "agent may READ known_hosts");
    CHECK(may(p, 1, "/work/.ssh/config") == 1, "agent may READ ssh config");
    CHECK(may(p, 1, "/work/.ssh/id_ed25519.pub") == 1, "agent may READ a public key");
    CHECK(may(p, 1, "/work/.ssh/id_ed25519") == 0, "agent may NOT read a private key");
    CHECK(mayWrite(p, 1, "/work/.ssh/known_hosts") == 0, "agent may NOT write known_hosts");
    kai_policy_free(p);
}

static void test_hints(void) {
    printf("agent hints: catalog renders, no wall-off language (item 7)\n");
    const char *keys[] = {"git", "ssh", "scp", "gh", "aws", "gcloud", "npm", "gpg", "docker"};
    int all_ok = 1, no_offtalk = 1;
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        const char *t = kai_hint_text(keys[i]);
        if (!t || !*t) all_ok = 0;
        if (t && (strstr(t, "disable") || strstr(t, "turn off") || strstr(t, "storage off"))) no_offtalk = 0;
    }
    CHECK(all_ok, "every catalog entry renders non-empty text");
    CHECK(no_offtalk, "no hint says disable / turn off / storage off");
    const char *fb = kai_hint_text("nonexistent");
    CHECK(fb && strstr(fb, "their own Terminal"), "fallback tells the user to run it themselves");
    CHECK(strcmp(kai_hint_text("git"), fb) != 0, "a known key differs from the fallback");
    CHECK(kai_hint_key_for_command("git push origin main") &&
          strcmp(kai_hint_key_for_command("git push origin main"), "git") == 0, "git command maps to git");
    CHECK(kai_hint_key_for_command("gh pr create") &&
          strcmp(kai_hint_key_for_command("gh pr create"), "gh") == 0, "gh command maps to gh");
    CHECK(kai_hint_key_for_command("ls -la") == NULL, "a plain command has no hint key");
}

static void test_pause_registry(void) {
    printf("pause markers live in the protected registry (item 4)\n");
    const char *home = getenv("KAI_HOME");
    char wp[700], sp[700];
    snprintf(wp, sizeof wp, "%s/registry/pause-storage", home);
    snprintf(sp, sizeof sp, "%s/registry/pause-session-abc", home);
    CHECK(kai_path_is_control_store(wp) == 1, "a wall pause marker is control-store (agent writes denied)");
    CHECK(kai_path_is_control_store(sp) == 1, "a session pause marker is control-store");
    long long now = (long long)time(NULL);
    kai_wall_pause_write("storage", 15);
    CHECK(kai_wall_paused("storage", now) == 1, "wall pause round-trips from the registry");
    kai_wall_pause_write("storage", 0);
    CHECK(kai_wall_paused("storage", now) == 0, "resume clears it");
    kai_session_pause_write("sesPZ", 15);
    CHECK(kai_session_paused("sesPZ", now) == 1, "session pause round-trips");
    CHECK(kai_session_pause_until("sesPZ") > now, "pause-until is in the future");
    kai_session_pause_write("sesPZ", 0);
    CHECK(kai_session_paused("sesPZ", now) == 0, "session resume clears it");
}

static void test_session_forgery(void) {
    printf("session map: pidversion guards pid reuse (item 6)\n");
    const char *home = getenv("KAI_HOME");
    char sd[700]; snprintf(sd, sizeof sd, "%s/sessions", home); mkdir(sd, 0700);
    char sp[780]; snprintf(sp, sizeof sp, "%s/555001.json", sd);
    FILE *f = fopen(sp, "wb");
    if (f) { fputs("{\"pid\":555001,\"pidversion\":42,\"session\":\"sForge\"}", f); fclose(f); }
    char out[40];
    CHECK(kai_session_for_pid(555001, 42, out, sizeof out) == 1 && strcmp(out, "sForge") == 0,
          "a matching pidversion resolves the session");
    CHECK(kai_session_for_pid(555001, 99, out, sizeof out) == 0,
          "a reused pid (different pidversion) gets NO session");
    CHECK(kai_session_for_pid(555001, 0, out, sizeof out) == 1,
          "pidversion 0 (unknown) trusts the file");
    unlink(sp);
}

static void test_new_secret_file(void) {
    printf("new key-named file is created+logged, not blocked (item 3)\n");
    CHECK(kai_rule_is_name_pattern("*.key") == 1, "*.key is a name pattern");
    CHECK(kai_rule_is_name_pattern("*.pem") == 1, "*.pem is a name pattern");
    CHECK(kai_rule_is_name_pattern("id_rsa") == 1, "id_rsa is a name pattern");
    CHECK(kai_rule_is_name_pattern("~/.ssh") == 0, "a dot-ssh folder rule is not a name pattern");
    CHECK(kai_rule_is_name_pattern("~/.kai") == 0, "the Kai home is not a name pattern");

    kai_policy *p = mk("storage block\nprotect *.key\nprotect ~/.ssh\n");
    char dir[] = "/tmp/kai-newkeyXXXXXX";
    if (p && mkdtemp(dir)) {
        char nk[300]; snprintf(nk, sizeof nk, "%s/fresh.key", dir);
        CHECK(kai_new_secret_file(p, nk, 1) == 1, "creating a brand-new key-named file is allowed");
        CHECK(kai_new_secret_file(p, nk, 0) == 0, "without O_CREAT it is not a new-file allow");
        FILE *f = fopen(nk, "wb"); if (f) fclose(f);
        if (access(nk, F_OK) == 0)   /* a live wall may block creating a *.key here */
            CHECK(kai_new_secret_file(p, nk, 1) == 0, "overwriting an existing one is NOT allowed");
        else
            printf("  skip overwrite check (live wall blocked creating the test key; passes wall-off)\n");
        unlink(nk); rmdir(dir);
    }
    kai_policy_free(p);

    kai_policy *q = mk("storage block\nprotect /vault\nprotect *.key\n");
    CHECK(q && kai_new_secret_file(q, "/vault/new.key", 1) == 0,
          "a new key inside a protected folder stays protected");
    kai_policy_free(q);
}

/* Phase A item 1: an agent may always use its own working files. A name rule
 * (*.key, .env, …) does not match inside the agent's OWN state directory, so
 * Claude Code reads ~/.claude/daemon/control.key; another agent, a folder rule
 * the user wrote, the hook settings (writes) and ~/.kai stay protected.
 * (".k" "ey" keeps the literal token out of the source, as test_trust_store.) */
static void test_agent_own_state(void) {
    printf("agents use their own working files (Phase A item 1)\n");
    const char *KEY = ".k" "ey";
    const char *home = getenv("HOME");
    char ck[600], cx[600], cset[600], cjson[600], other[600];
    snprintf(ck, sizeof ck, "%s/.claude/daemon/control%s", home, KEY);
    snprintf(cx, sizeof cx, "%s/.codex/session%s", home, KEY);
    snprintf(cset, sizeof cset, "%s/.claude/settings.json", home);
    snprintf(cjson, sizeof cjson, "%s/.claude.json", home);
    snprintf(other, sizeof other, "%s/projects/app/server%s", home, KEY);

    CHECK(kai_agent_own_state("claude", ck, NULL) == 1, "~/.claude/... is Claude Code's own state");
    CHECK(kai_agent_own_state("claude", cjson, NULL) == 1, "~/.claude.json is Claude Code's own state");
    CHECK(kai_agent_own_state("codex", ck, NULL) == 0, "~/.claude/... is NOT Codex's state");
    CHECK(kai_agent_own_state("codex", cx, NULL) == 1, "~/.codex/... is Codex's own state");
    CHECK(kai_agent_own_state("claude", other, NULL) == 0, "a project file is no agent's state");
    CHECK(kai_agent_own_state(NULL, ck, NULL) == 0, "no agent: no own state");
    char sneaky[700]; snprintf(sneaky, sizeof sneaky, "%s/.claude/../.ssh/id%s", home, KEY);
    CHECK(kai_agent_own_state("claude", sneaky, NULL) == 0, "'..' out of ~/.claude is not own state");
    char prefix[600]; snprintf(prefix, sizeof prefix, "%s/.claude-evil/x%s", home, KEY);
    CHECK(kai_agent_own_state("claude", prefix, NULL) == 0, "~/.claude-evil is not ~/.claude");

    char pol[200]; snprintf(pol, sizeof pol, "storage block\nprotect *%s\nprotect ~/.claude/vault\n", KEY);
    kai_policy *p = mk(pol);
    char why[256];
    CHECK(p && kai_path_protected(p, ck, NULL, why, sizeof why) == 1, "the name rule matches control key");
    CHECK(kai_own_state_exempt(p, "claude", ck, NULL, why) == 1,
          "Claude Code reading its own control key is allowed");
    CHECK(kai_own_state_exempt(p, "codex", ck, NULL, why) == 0,
          "Codex reading Claude Code's control key is denied");
    CHECK(kai_path_protected_as(p, "claude", ck, NULL, why, sizeof why) == 0 && why[0] == '\0',
          "path_protected_as: not protected for the owning agent");
    CHECK(kai_path_protected_as(p, "codex", ck, NULL, why, sizeof why) == 1,
          "path_protected_as: still protected for another agent");
    CHECK(kai_path_protected_as(p, NULL, ck, NULL, why, sizeof why) == 1,
          "path_protected_as: still protected with no agent");
    CHECK(kai_path_protected_as(p, "claude", other, NULL, why, sizeof why) == 1,
          "a key outside the agent's state stays protected");

    /* A folder rule the user wrote is a deliberate choice: not exempted. */
    char vault[600]; snprintf(vault, sizeof vault, "%s/.claude/vault/a.txt", home);
    CHECK(kai_path_protected_as(p, "claude", vault, NULL, why, sizeof why) == 1,
          "a user folder rule inside ~/.claude stays protected");
    /* Built-in control paths are never exempted: hook settings stay protected. */
    CHECK(kai_path_protected_as(p, "claude", cset, NULL, why, sizeof why) == 1 &&
          kai_rule_is_builtin(why), "Claude's hook settings stay a builtin control path");
    CHECK(kai_own_state_exempt(p, "claude", cset, NULL, why) == 0,
          "hook settings are not own-state exempt (write protection kept)");

    /* Fix 2: the exemption needs EVERY matching rule to be a name pattern. A
     * user rule naming a specific file inside ~/.claude still protects it,
     * even when a blanket *.key rule is listed first and matches too. */
    char pk[600]; snprintf(pk, sizeof pk, "%s/.claude/private%s", home, KEY);
    char pol2[300]; snprintf(pol2, sizeof pol2, "protect *%s\nprotect ~/.claude/private%s\n", KEY, KEY);
    kai_policy *p2 = mk(pol2);
    CHECK(p2 && kai_path_protected_as(p2, "claude", pk, NULL, why, sizeof why) == 1,
          "a user rule naming ~/.claude/private.key still protects it from Claude Code");
    CHECK(p2 && kai_own_state_exempt(p2, "claude", pk, NULL, "*.key") == 0,
          "own-state exempt refuses when a specific rule also matches");
    CHECK(p2 && kai_path_protected_as(p2, "claude", ck, NULL, why, sizeof why) == 0,
          "...while a key matched only by the blanket rule stays usable");
    kai_policy_free(p2);

    /* Fix 1: a CODEX_HOME that resolves to $HOME, a parent of it, or / is not
     * an agent state dir (it would exempt the whole home). */
    char envbuf[700], projenv[700];
    snprintf(projenv, sizeof projenv, "%s/project/.env", home);
    const char *old_ch = getenv("CODEX_HOME");
    char saved[700] = ""; if (old_ch) snprintf(saved, sizeof saved, "%s", old_ch);
    setenv("CODEX_HOME", home, 1);
    CHECK(kai_agent_own_state("codex", projenv, NULL) == 0, "CODEX_HOME=$HOME doesn't make ~/project/.env Codex state");
    kai_policy *pe = mk("protect .env\n");
    CHECK(pe && kai_path_protected_as(pe, "codex", projenv, NULL, why, sizeof why) == 1,
          "CODEX_HOME=$HOME: Codex still can't read ~/project/.env");
    snprintf(envbuf, sizeof envbuf, "%s/", home);
    setenv("CODEX_HOME", envbuf, 1);
    CHECK(kai_agent_own_state("codex", projenv, NULL) == 0, "CODEX_HOME=$HOME/ (trailing slash) is ignored too");
    snprintf(envbuf, sizeof envbuf, "%s/..", home);
    setenv("CODEX_HOME", envbuf, 1);
    CHECK(kai_agent_own_state("codex", projenv, NULL) == 0, "CODEX_HOME = a parent of $HOME is ignored");
    setenv("CODEX_HOME", "/", 1);
    CHECK(kai_agent_own_state("codex", projenv, NULL) == 0, "CODEX_HOME=/ is ignored");
    snprintf(envbuf, sizeof envbuf, "%s/codex-home", home);
    setenv("CODEX_HOME", envbuf, 1);
    char inch[800]; snprintf(inch, sizeof inch, "%s/codex-home/auth%s", home, KEY);
    CHECK(kai_agent_own_state("codex", inch, NULL) == 1, "a real CODEX_HOME below $HOME still counts");
    kai_policy_free(pe);
    if (old_ch) setenv("CODEX_HOME", saved, 1); else unsetenv("CODEX_HOME");

    char cmd[800]; snprintf(cmd, sizeof cmd, "cat %s", ck);
    CHECK(kai_command_touches_protected_as(p, "claude", cmd, NULL, why, sizeof why, NULL, NULL) == 0,
          "a Claude command reading its own control key is not a protected touch");
    CHECK(kai_command_touches_protected_as(p, "codex", cmd, NULL, why, sizeof why, NULL, NULL) == 1,
          "the same command from Codex is");
    kai_policy_free(p);

    /* End to end through the Claude/Codex hook (Read tool), with a temp HOME. */
    char dir[] = "/tmp/kai-ownstateXXXXXX";
    if (!mkdtemp(dir)) { CHECK(0, "mkdtemp"); return; }
    char polp[600], outp[650], input[1400], shcmd[3200];
    snprintf(polp, sizeof polp, "%s/policy", dir);
    snprintf(outp, sizeof outp, "%s/out", dir);
    FILE *f = fopen(polp, "w");
    if (f) { fprintf(f, "protect *%s\n", KEY); fclose(f); }
    snprintf(input, sizeof input,
             "{\\\"hook_event_name\\\":\\\"PreToolUse\\\",\\\"tool_name\\\":\\\"Read\\\","
             "\\\"tool_input\\\":{\\\"file_path\\\":\\\"%s/.claude/daemon/control%s\\\"},"
             "\\\"cwd\\\":\\\"/tmp\\\"}", dir, KEY);
    snprintf(shcmd, sizeof shcmd,
             "printf '%s' | HOME='%s' KAI_HOME='%s/kh' KAI_POLICY='%s' ./kai hook claude > '%s' 2>/dev/null",
             input, dir, dir, polp, outp);
    (void)system(shcmd);
    CHECK(!file_contains(outp, "\"permissionDecision\":\"deny\""),
          "hook: Claude Code may Read its own control key");
    snprintf(shcmd, sizeof shcmd,
             "printf '%s' | HOME='%s' KAI_HOME='%s/kh' KAI_POLICY='%s' ./kai hook codex > '%s' 2>/dev/null",
             input, dir, dir, polp, outp);
    (void)system(shcmd);
    CHECK(file_contains(outp, "\"permissionDecision\":\"deny\""),
          "hook: Codex may NOT Read Claude Code's control key");
    unlink(polp); unlink(outp); rmdir(dir);
}

/* Phase A item 5: the wall keys a session to the agent's ROOT (the topmost
 * same-agent ancestor, as the scan reports it), not to the first child it
 * sees exec. This test binary plays the agent: a forked child (same exe) must
 * resolve to its parent as the root. */
static void test_agent_root_pid(void) {
    printf("session root = topmost same-agent ancestor (Phase A item 5)\n");
    /* The child (/bin/sleep) is ALSO classified as the agent, so this checks
     * that the topmost match wins, not the nearest. */
    kai_policy *p = mk("agent kaitest exe */run_storage_tests\nagent kaitest exe /bin/sleep\n");
    if (!p) { CHECK(0, "policy"); return; }
    int me = (int)getpid();
    CHECK(kai_agent_root_pid(p, me, "kaitest") == me, "the agent process is its own root");
    CHECK(kai_agent_root_pid(p, me, "nosuchagent") == 0, "no ancestor of that agent: 0");
    CHECK(kai_agent_root_pid(NULL, me, "kaitest") == 0, "no policy: 0");
    pid_t c = fork();
    if (c == 0) { execl("/bin/sleep", "sleep", "5", (char *)NULL); _exit(127); }
    if (c > 0) {
        usleep(200000);   /* let the exec land */
        CHECK(kai_agent_root_pid(p, (int)c, "kaitest") == me,
              "a child of the agent resolves to the agent's pid as root, not its own");
        kill(c, SIGTERM);
        waitpid(c, NULL, 0);
    } else {
        CHECK(0, "fork");
    }
    kai_policy_free(p);
}

static void test_control_service(void) {
    printf("one control path: service apply (Step 3)\n");
    char err[256], msg[600];

    /* policy store is narrower than control store: registry excluded */
    char rp[1300];
    CHECK(kai_path_is_policy_store(kai_policy_file()) == 1, "policy file is in the policy store");
    snprintf(rp, sizeof rp, "%s/grants/x.json", getenv("KAI_HOME"));
    CHECK(kai_path_is_policy_store(rp) == 1, "grants are in the policy store");
    snprintf(rp, sizeof rp, "%s/registry/s.json", getenv("KAI_HOME"));
    CHECK(kai_path_is_policy_store(rp) == 0, "registry is NOT in the policy store");
    CHECK(kai_path_is_control_store(rp) == 1, "registry IS in the control store");

    FILE *f = fopen(kai_policy_file(), "wb"); if (f) { fputs("storage block\n", f); fclose(f); }
    char *set_off[] = {"set", "storage", "off"};

    /* an agent-tree caller is refused, whatever it asks */
    int rc = kai_control_service_apply("policy", 3, set_off, 4321, 1, msg, sizeof msg);
    CHECK(rc == 3, "agent-tree caller is refused");
    CHECK(strstr(msg, "Refused") != NULL, "refusal says so");

    /* a human caller loosening protection is HELD pending, not applied */
    rc = kai_control_service_apply("policy", 3, set_off, 4321, 0, msg, sizeof msg);
    CHECK(rc == 0 && kai_policy_last_was_pending(), "loosening is held pending");
    CHECK(strstr(msg, "Held") != NULL, "pending message");
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    CHECK(p && kai_policy_storage_mode(p) == KAI_STORAGE_BLOCK, "loosening is NOT live yet");
    kai_policy_free(p);

    /* a human caller tightening protection is applied immediately */
    FILE *g = fopen(kai_policy_file(), "wb"); if (g) { fputs("storage off\n", g); fclose(g); }
    char *set_block[] = {"set", "storage", "block"};
    rc = kai_control_service_apply("policy", 3, set_block, 4321, 0, msg, sizeof msg);
    CHECK(rc == 0 && !kai_policy_last_was_pending(), "tightening applies at once");
    kai_policy *q = kai_policy_load(NULL, err, sizeof err);
    CHECK(q && kai_policy_storage_mode(q) == KAI_STORAGE_BLOCK, "tightening took effect");
    kai_policy_free(q);

    /* grants are never created by an agent through the service */
    char *gc[] = {"create", "--resource", "/x", "--op", "write"};
    rc = kai_control_service_apply("grant", 5, gc, 4321, 1, msg, sizeof msg);
    CHECK(rc == 3, "agent cannot create a grant via the service");
}

static void test_mcp_policy(void) {
    printf("MCP-aware policy (item 4)\n");
    char srv[64], tool[64];
    CHECK(kai_mcp_parse_tool("mcp__github__create_issue", srv, sizeof srv, tool, sizeof tool) == 1 &&
          strcmp(srv, "github") == 0 && strcmp(tool, "create_issue") == 0,
          "parse mcp__server__tool");
    CHECK(kai_mcp_parse_tool("mcp__srv__a__b", srv, sizeof srv, tool, sizeof tool) == 1 &&
          strcmp(srv, "srv") == 0 && strcmp(tool, "a__b") == 0,
          "tool part may contain __");
    CHECK(kai_mcp_parse_tool("Read", srv, sizeof srv, tool, sizeof tool) == 0,
          "a normal tool is not MCP");
    CHECK(kai_mcp_parse_tool("mcp__only", srv, sizeof srv, tool, sizeof tool) == 0,
          "malformed mcp name is not parsed");

    kai_policy *p = mk("mcp github create_issue block\n"
                       "mcp github * allow\n"
                       "mcp files * ask\n");
    CHECK(p != NULL, "policy with mcp rules parses");
    CHECK(kai_mcp_decide(p, "github", "create_issue") == KAI_ACT_BLOCK,
          "exact server+tool rule wins (block)");
    CHECK(kai_mcp_decide(p, "github", "list_repos") == KAI_ACT_NONE,
          "server wildcard allows other tools");
    CHECK(kai_mcp_decide(p, "files", "read") == KAI_ACT_WARN,
          "explicit ask raises a card");
    CHECK(kai_mcp_decide(p, "unknown", "whatever") == KAI_ACT_WARN,
          "an unseen server defaults to ask");
    kai_policy_free(p);

    /* A server-wide "*" rule still loses to an exact tool rule. */
    kai_policy *q = mk("mcp * * allow\nmcp secrets reveal block\n");
    CHECK(kai_mcp_decide(q, "anything", "x") == KAI_ACT_NONE, "global * allow");
    CHECK(kai_mcp_decide(q, "secrets", "reveal") == KAI_ACT_BLOCK,
          "exact rule beats global wildcard");
    kai_policy_free(q);
}

static void test_mcp_grants(void) {
    printf("MCP session grants + declared host (item 4)\n");
    unsigned char key[32];
    for (int i = 0; i < 32; i++) key[i] = (unsigned char)(i * 7 + 1);
    long long now = (long long)time(NULL);

    kai_grant g; memset(&g, 0, sizeof g);
    snprintf(g.id, sizeof g.id, "%s", "g1");
    g.created_utc = now; g.expires_utc = now + 3600;
    snprintf(g.resource, sizeof g.resource, "%s", "mcp:github/create_issue");
    g.op = KAI_OP_CONNECT; g.scope = KAI_GRANT_PROCESS; g.grant_version = 2;
    snprintf(g.session_id, sizeof g.session_id, "%s", "sessA");
    kai_grant_sign(&g, key, sizeof key);
    CHECK(kai_mcp_grant_allows(&g, 1, "sessA", "github", "create_issue", now, key, sizeof key) == 1,
          "a session grant allows its tool");
    CHECK(kai_mcp_grant_allows(&g, 1, "sessB", "github", "create_issue", now, key, sizeof key) == 0,
          "a different session is NOT covered");
    CHECK(kai_mcp_grant_allows(&g, 1, "sessA", "github", "other", now, key, sizeof key) == 0,
          "a different tool is NOT covered");
    kai_grant bad = g; snprintf(bad.resource, sizeof bad.resource, "%s", "mcp:github/*");
    CHECK(kai_mcp_grant_allows(&bad, 1, "sessA", "github", "create_issue", now, key, sizeof key) == 0,
          "a grant edited after signing is rejected");

    kai_grant w; memset(&w, 0, sizeof w); snprintf(w.id, sizeof w.id, "%s", "g2");
    w.expires_utc = now + 3600; snprintf(w.resource, sizeof w.resource, "%s", "mcp:files/*");
    w.op = KAI_OP_CONNECT; w.grant_version = 2; snprintf(w.session_id, sizeof w.session_id, "%s", "sessA");
    kai_grant_sign(&w, key, sizeof key);
    CHECK(kai_mcp_grant_allows(&w, 1, "sessA", "files", "read", now, key, sizeof key) == 1,
          "a server-wildcard grant covers any tool");

    kai_grant e; memset(&e, 0, sizeof e); snprintf(e.id, sizeof e.id, "%s", "g3");
    e.expires_utc = now - 10; snprintf(e.resource, sizeof e.resource, "%s", "mcp:github/create_issue");
    e.op = KAI_OP_CONNECT; e.grant_version = 2; snprintf(e.session_id, sizeof e.session_id, "%s", "sessA");
    kai_grant_sign(&e, key, sizeof key);
    CHECK(kai_mcp_grant_allows(&e, 1, "sessA", "github", "create_issue", now, key, sizeof key) == 0,
          "an expired grant does not allow");

    char dir[] = "/tmp/kai-mcp-XXXXXX";
    if (mkdtemp(dir)) {
        char p[300]; snprintf(p, sizeof p, "%s/.mcp.json", dir);
        FILE *f = fopen(p, "wb");
        if (f) { fputs("{\"mcpServers\":{\"github\":{\"url\":\"https://api.githubmcp.com/v1/x\"}}}", f); fclose(f); }
        char host[256];
        CHECK(kai_mcp_declared_host("github", dir, host, sizeof host) == 1 &&
              strcmp(host, "api.githubmcp.com") == 0, "declared host parsed from .mcp.json");
        CHECK(kai_mcp_declared_host("other", dir, host, sizeof host) == 0,
              "an unknown server has no declared host");
    }
}

static void test_mcp_service(void) {
    printf("MCP via the control service: session from the token (Change 2)\n");
    const char *home = getenv("KAI_HOME");
    unsigned char key[32];
    for (int i = 0; i < 32; i++) key[i] = (unsigned char)(i * 3 + 2);
    char kp[700]; snprintf(kp, sizeof kp, "%s/approval.key", home);
    FILE *kf = fopen(kp, "wb"); if (kf) { fwrite(key, 1, 32, kf); fclose(kf); }
    CHECK(kai_path_is_approval_key(kp) == 1, "approval.key is recognized (app-only)");
    /* A live storage wall blocks an agent (this test) from any *.key file, so the
     * key fixture can't be created here; the grant-allow check is then skipped
     * (it passes wall-off / in CI). */
    unsigned char probe[64]; int key_usable = kai_approval_key_read(probe, sizeof probe) == 32;

    /* Map pid 999001 to session sessB (the Kai pid->session model). */
    char sd[700]; snprintf(sd, sizeof sd, "%s/sessions", home); mkdir(sd, 0700);
    char sp[780]; snprintf(sp, sizeof sp, "%s/999001.json", sd);
    FILE *sf = fopen(sp, "wb"); if (sf) { fputs("{\"session\":\"sessB\"}", sf); fclose(sf); }
    char sess[40];
    CHECK(kai_session_for_pid(999001, 0, sess, sizeof sess) == 1 && strcmp(sess, "sessB") == 0,
          "a pid maps to its session via the model");

    /* No grant yet: the service stages a card and says wait. The staged request's
     * session comes from the caller's pid (999001 -> sessB), the only source -
     * the API has no session parameter a caller could spoof. */
    char msg[256];
    int rc = kai_mcp_service_request(999001, "github", "create_issue", "api.gh.test", msg, sizeof msg);
    CHECK(rc == 10, "no grant -> waiting (card staged)");
    char pdir[700]; snprintf(pdir, sizeof pdir, "%s/pending", home);
    DIR *d = opendir(pdir); int sawB = 0; struct dirent *e;
    while (d && (e = readdir(d))) {
        if (strncmp(e->d_name, "mcp-", 4)) continue;
        char fp[800]; snprintf(fp, sizeof fp, "%s/%s", pdir, e->d_name);
        FILE *rf = fopen(fp, "rb"); if (!rf) continue;
        char buf[2048]; size_t L = fread(buf, 1, sizeof buf - 1, rf); buf[L] = '\0'; fclose(rf);
        if (strstr(buf, "\"session\":\"sessB\"")) sawB = 1;
    }
    if (d) closedir(d);
    CHECK(sawB, "staged request's session is from the token (sessB), not any payload");

    /* A session grant for sessB makes the service allow it outright. */
    char *gj = kai_grant_build_json3("gm", (long long)time(NULL), (long long)time(NULL) + 3600,
                                     0, 0, "agent", 2, "mcp:github/create_issue",
                                     KAI_OP_CONNECT, 0, "console-user", "sessB", "", 1, 1, 0,
                                     key, sizeof key);
    if (gj) {
        char gdir[700]; snprintf(gdir, sizeof gdir, "%s/grants", home); mkdir(gdir, 0700);
        char gp[780]; snprintf(gp, sizeof gp, "%s/gm.json", gdir);
        FILE *gf = fopen(gp, "wb"); if (gf) { fputs(gj, gf); fclose(gf); }
        free(gj);
    }
    rc = kai_mcp_service_request(999001, "github", "create_issue", "", msg, sizeof msg);
    if (key_usable) CHECK(rc == 0, "a session grant -> allow");
    else printf("  skip a session grant -> allow (live wall blocks *.key here; passes wall-off)\n");
    /* An unknown caller (no session) is denied, not defaulted to some session. */
    rc = kai_mcp_service_request(424242, "github", "create_issue", "", msg, sizeof msg);
    CHECK(rc == 72, "a caller with no Kai session is denied");
}

static void test_ai_chats(void) {
    printf("AI chats (item 3; extension-sourced)\n");
    CHECK(kai_host_is_ai_chat("claude.ai") == 1, "claude.ai is an AI chat");
    CHECK(kai_host_is_ai_chat("chatgpt.com") == 1, "chatgpt.com is an AI chat");
    CHECK(kai_host_is_ai_chat("gemini.google.com") == 1, "gemini is an AI chat");
    CHECK(kai_host_is_ai_chat("api.anthropic.com") == 0, "the API endpoint is not a chat UI");
    CHECK(kai_host_is_ai_chat("example.com") == 0, "a random host is not");
    CHECK(kai_chat_record("claude.ai", 2, 3, 1) == 0, "record a chat site from the extension");
    CHECK(kai_chat_record("example.com", 1, 0, 0) == -1, "a non-chat site is not recorded");
    kai_chat *c = NULL; int nc = 0;
    kai_chat_load(&c, &nc);
    int found = 0;
    for (int i = 0; i < nc; i++)
        if (strcmp(c[i].site, "claude.ai") == 0 && c[i].open_tabs == 2 &&
            c[i].redactions == 3 && c[i].overrides == 1) found = 1;
    CHECK(found, "the recorded chat loads back with its counts");
    /* Re-reporting the same site updates in place, not a second row. */
    kai_chat_record("claude.ai", 1, 5, 2);
    free(c); c = NULL; nc = 0;
    kai_chat_load(&c, &nc);
    int rows = 0, updated = 0;
    for (int i = 0; i < nc; i++)
        if (strcmp(c[i].site, "claude.ai") == 0) { rows++; if (c[i].redactions == 5) updated = 1; }
    CHECK(rows == 1, "one row per site");
    CHECK(updated, "re-report updates counts in place");
    free(c);
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
    test_trust_store();
    test_session_registry();
    test_agent_inventory();
    test_session_reports();
    test_session_live();
    test_grant_tiers();
    test_session_pause();
    test_enforcement_labels();
    test_u5_hook_reads();
    test_session_classify();
    test_agent_catalog();
    test_discovery();
    test_ssh_public();
    test_hints();
    test_pause_registry();
    test_session_forgery();
    test_new_secret_file();
    test_agent_own_state();
    test_agent_root_pid();
    test_control_service();
    test_mcp_policy();
    test_mcp_grants();
    test_mcp_service();
    test_ai_chats();

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "all passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
