/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Unit tests for src/watch.c, the logic of the Windows Watch service: process
 * tree tagging (spawn chains, nested agents, PID reuse, lost events), DNS to
 * connection attribution, and the protected-file filter (with libkai's real
 * policy). No ETW, no service: events are made up here.
 */
#include "internal.h"
#include "kai.h"
#include "watch.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; printf("  FAIL: %s\n", msg); } } while (0)

#define S(n) ((uint64_t)(n) * KAI_TICKS_PER_SEC)   /* seconds -> ticks */
#define T0 S(1000000)

/* ---- recorder ---- */
typedef struct {
    int n;
    char agent[16][32], host[16][128], from[16][16], ip[16][64], path[16][512];
    uint32_t pid[16];
    int port[16];
} rec_t;
static rec_t rec;
static void rec_reset(void) { memset(&rec, 0, sizeof rec); }

static int classify(void *ctx, uint32_t pid, const char *image, char *agent, size_t an, char *ident, size_t in) {
    (void)ctx; (void)pid;
    const char *b = strrchr(image, '/') ? strrchr(image, '/') + 1 : image;
    if (strrchr(b, '\\')) b = strrchr(b, '\\') + 1;
    const char *name = !strcmp(b, "claude.exe") ? "claude" : !strcmp(b, "codex.exe") ? "codex"
                     : !strcmp(b, "Cursor.exe") ? "cursor" : NULL;
    if (!name) return 0;
    snprintf(agent, an, "%s", name);
    snprintf(ident, in, "%s", "test signer");
    return 1;
}

static void on_connect(void *ctx, const kai_watch_event *e) {
    (void)ctx;
    if (rec.n >= 16) return;
    int i = rec.n++;
    snprintf(rec.agent[i], sizeof rec.agent[i], "%s", e->agent);
    snprintf(rec.host[i], sizeof rec.host[i], "%s", e->host ? e->host : "");
    snprintf(rec.from[i], sizeof rec.from[i], "%s", e->host_from ? e->host_from : "");
    snprintf(rec.ip[i], sizeof rec.ip[i], "%s", e->ip);
    rec.pid[i] = e->pid;
    rec.port[i] = e->port;
}

static kai_policy *pol;
static int file_protected(void *ctx, const char *agent, const char *path, char *rule, size_t n) {
    (void)ctx;
    return kai_path_protected_as(pol, agent, path, NULL, rule, n);
}

static void on_file(void *ctx, const kai_watch_event *e) {
    (void)ctx;
    if (rec.n >= 16) return;
    int i = rec.n++;
    snprintf(rec.agent[i], sizeof rec.agent[i], "%s", e->agent);
    snprintf(rec.path[i], sizeof rec.path[i], "%s", e->path);
    rec.pid[i] = e->pid;
}

static kai_watch *fresh(void) {
    kai_watch_ops ops = {NULL, classify, on_connect, file_protected, on_file};
    rec_reset();
    return kai_watch_new(&ops);
}

static void test_tree(void) {
    printf("process tree tagging\n");
    kai_watch *w = fresh();
    char a[32];
    kai_watch_process_start(w, 4, 0, T0, "System");
    kai_watch_process_start(w, 1000, 4, T0 + S(1), "C:/Windows/explorer.exe");
    kai_watch_process_start(w, 100, 1000, T0 + S(10), "C:/Users/ann/.local/bin/claude.exe");
    kai_watch_process_start(w, 200, 100, T0 + S(11), "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe");
    kai_watch_process_start(w, 300, 200, T0 + S(12), "C:/Windows/System32/curl.exe");
    kai_watch_process_start(w, 400, 1000, T0 + S(13), "C:/Program Files/Git/bin/bash.exe");
    CHECK(kai_watch_tagged(w, 100, 0, a, sizeof a) && !strcmp(a, "claude"), "the agent itself is tagged");
    CHECK(kai_watch_tagged(w, 300, 0, a, sizeof a) && !strcmp(a, "claude"), "grandchild (curl under powershell) is tagged claude");
    CHECK(!kai_watch_tagged(w, 400, 0, a, sizeof a), "a sibling under explorer is not tagged");
    CHECK(!kai_watch_tagged(w, 1000, 0, a, sizeof a), "the agent's parent is not tagged");

    /* nested agent: Claude Code starts Codex; Codex's children are Codex's */
    kai_watch_process_start(w, 500, 200, T0 + S(14), "C:/Users/ann/AppData/Local/Programs/OpenAI/Codex/bin/codex.exe");
    kai_watch_process_start(w, 504, 500, T0 + S(15), "C:/Windows/System32/cmd.exe");
    CHECK(kai_watch_tagged(w, 504, 0, a, sizeof a) && !strcmp(a, "codex"), "the nearest agent names the tag");

    /* a child started after its parent exited and the parent PID was reused */
    kai_watch_process_stop(w, 200, T0 + S(11), T0 + S(20));
    kai_watch_process_start(w, 200, 1000, T0 + S(21), "C:/Windows/notepad.exe");
    kai_watch_process_start(w, 600, 200, T0 + S(22), "C:/Windows/System32/conhost.exe");
    CHECK(!kai_watch_tagged(w, 600, 0, a, sizeof a), "child of a reused parent PID is not tagged");
    CHECK(!kai_watch_tagged(w, 200, 0, a, sizeof a), "the new process on a reused PID is not tagged");
    CHECK(kai_watch_tagged(w, 200, T0 + S(15), a, sizeof a) && !strcmp(a, "claude"),
          "an event from before the exit still finds the old process");

    /* PID reuse of the tagged curl */
    kai_watch_process_stop(w, 300, T0 + S(12), T0 + S(30));
    kai_watch_process_start(w, 300, 1000, T0 + S(40), "C:/Program Files/Mozilla Firefox/firefox.exe");
    kai_watch_connect(w, 300, T0 + S(41), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 0, "a connect from the reused PID is not recorded");
    kai_watch_connect(w, 300, T0 + S(29), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 1 && !strcmp(rec.agent[0], "claude"), "a late connect event from the old curl is recorded as claude");
    kai_watch_connect(w, 300, T0 + S(31), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 2, "an event within 2 s of the exit still belongs to the old process");
    kai_watch_connect(w, 300, T0 + S(35), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 2, "an event 5 s after the exit, before the reuse, belongs to nobody");

    /* a lost stop event: a new start with the same PID ends the old one */
    kai_watch_process_start(w, 700, 100, T0 + S(50), "C:/Windows/System32/curl.exe");
    kai_watch_process_start(w, 700, 1000, T0 + S(60), "C:/Windows/System32/svchost.exe");
    CHECK(!kai_watch_tagged(w, 700, 0, a, sizeof a), "lost stop event: the newer process wins");
    CHECK(kai_watch_tagged(w, 700, T0 + S(55), a, sizeof a), "lost stop event: the older one still answers for its time");

    /* snapshot resync after event loss: processes not seen are marked exited */
    kai_watch_sync_begin(w);
    kai_watch_process_start(w, 100, 1000, T0 + S(10), "C:/Users/ann/.local/bin/claude.exe");
    kai_watch_process_start(w, 1000, 4, T0 + S(1), "C:/Windows/explorer.exe");
    kai_watch_process_start(w, 800, 100, T0 + S(70), "C:/Windows/System32/whoami.exe");
    kai_watch_sync_end(w, T0 + S(80));
    CHECK(kai_watch_tagged(w, 800, 0, a, sizeof a), "resync adds a process whose start event was lost, tagged");
    CHECK(!kai_watch_tagged(w, 504, 0, a, sizeof a), "resync ends a process that is gone");

    /* ETW per-CPU buffers: a child's (and grandchild's) start event delivered
     * before the agent's own */
    kai_watch_process_start(w, 910, 900, T0 + S(91), "C:/Windows/System32/cmd.exe");
    kai_watch_process_start(w, 920, 910, T0 + S(92), "C:/Windows/System32/curl.exe");
    CHECK(!kai_watch_tagged(w, 920, 0, a, sizeof a), "before the agent's start event arrives: not tagged yet");
    kai_watch_process_start(w, 900, 1000, T0 + S(90), "C:/Users/ann/.local/bin/claude.exe");
    CHECK(kai_watch_tagged(w, 910, 0, a, sizeof a) && !strcmp(a, "claude"), "late parent: its child takes its tag");
    CHECK(kai_watch_tagged(w, 920, 0, a, sizeof a) && !strcmp(a, "claude"), "late parent: and the grandchild");
    kai_watch_process_start(w, 940, 930, T0 + S(93), "C:/Windows/System32/cmd.exe");
    kai_watch_process_start(w, 930, 1000, T0 + S(95), "C:/Users/ann/.local/bin/claude.exe");
    CHECK(!kai_watch_tagged(w, 940, 0, a, sizeof a), "a parent PID that started after the child isn't its parent");
    kai_watch_sync_begin(w);
    kai_watch_process_start(w, 100, 1000, T0 + S(10), "C:/Users/ann/.local/bin/claude.exe");
    kai_watch_process_start(w, 1000, 4, T0 + S(1), "C:/Windows/explorer.exe");
    kai_watch_process_start(w, 800, 100, T0 + S(70), "C:/Windows/System32/whoami.exe");
    kai_watch_sync_end(w, T0 + S(96));

    kai_watch_stats st;
    kai_watch_gc(w, T0 + S(96) + S(61));
    kai_watch_get_stats(w, &st);
    CHECK(st.procs == 3 && st.tagged == 2, "gc keeps the processes the snapshot saw (explorer, claude, whoami)");
    CHECK(!kai_watch_tagged(w, 300, T0 + S(29), a, sizeof a), "gc dropped exited processes");
    kai_watch_free(w);
}

static void test_dns(void) {
    printf("DNS to connection attribution\n");
    kai_watch *w = fresh();
    kai_watch_process_start(w, 1000, 4, T0, "C:/Windows/explorer.exe");
    kai_watch_process_start(w, 100, 1000, T0 + S(1), "C:/Users/ann/.local/bin/claude.exe");
    kai_watch_process_start(w, 300, 100, T0 + S(2), "C:/Windows/System32/curl.exe");
    kai_watch_process_start(w, 900, 4, T0 + S(3), "C:/Windows/System32/svchost.exe");
    kai_watch_process_start(w, 950, 1000, T0 + S(3), "C:/Program Files/Mozilla Firefox/firefox.exe");

    kai_watch_dns(w, 300, T0 + S(5), "example.com", "::ffff:93.184.216.34;");
    kai_watch_connect(w, 300, T0 + S(6), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 1 && !strcmp(rec.host[0], "example.com") && !strcmp(rec.from[0], "process"),
          "the process' own lookup names the host");

    kai_watch_dns(w, 100, T0 + S(7), "api.anthropic.com.", "type:  5 api.anthropic.com.cdn.cloudflare.net;160.79.104.10;");
    kai_watch_connect(w, 300, T0 + S(8), "tcp", "160.79.104.10", 443);
    CHECK(rec.n == 2 && !strcmp(rec.host[1], "api.anthropic.com") && !strcmp(rec.from[1], "agent"),
          "a lookup by the agent names its child's connection (CNAME skipped, trailing dot dropped)");

    kai_watch_dns(w, 900, T0 + S(9), "registry.npmjs.org", "104.16.0.35;2606:4700::6810:23;");
    kai_watch_connect(w, 300, T0 + S(10), "tcp", "104.16.0.35", 443);
    CHECK(rec.n == 3 && !strcmp(rec.host[2], "registry.npmjs.org") && !strcmp(rec.from[2], "machine"),
          "a lookup by another process (the DNS service) is marked as the machine's");
    kai_watch_connect(w, 300, T0 + S(11), "tcp", "[2606:4700::6810:23]", 443);
    CHECK(rec.n == 4 && !strcmp(rec.host[3], "registry.npmjs.org") && !strcmp(rec.ip[3], "2606:4700::6810:23"),
          "IPv6 answer and bracketed address match");

    kai_watch_dns(w, 950, T0 + S(12), "evil.example", "203.0.113.9;");
    kai_watch_dns(w, 300, T0 + S(12), "good.example", "203.0.113.9;");
    kai_watch_dns(w, 950, T0 + S(13), "evil.example", "203.0.113.9;");
    kai_watch_connect(w, 300, T0 + S(14), "tcp", "203.0.113.9", 443);
    CHECK(rec.n == 5 && !strcmp(rec.host[4], "good.example"),
          "the process' own answer wins over a newer one from another process");

    kai_watch_connect(w, 300, T0 + S(15), "udp", "198.51.100.7", 53);
    CHECK(rec.n == 6 && rec.host[5][0] == '\0' && rec.port[5] == 53, "no lookup: the address only, no guess");

    kai_watch_connect(w, 950, T0 + S(16), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 6, "an untagged process' connection is never recorded");

    kai_watch_connect(w, 300, T0 + S(5) + S(601), "tcp", "93.184.216.34", 443);
    CHECK(rec.n == 7 && rec.host[6][0] == '\0', "an answer older than 10 minutes isn't used");
    kai_watch_connect(w, 300, T0 + S(20), "tcp", "not-an-ip", 443);
    CHECK(rec.n == 7, "a malformed address is dropped");

    /* ETW order: a short-lived child's lookup and connect arrive before its
     * own start event; they wait for it */
    kai_watch_dns(w, 330, T0 + S(700), "late.example", "192.0.2.44;");
    kai_watch_connect(w, 330, T0 + S(700), "tcp", "192.0.2.44", 443);
    CHECK(rec.n == 7, "a connect from a PID not known yet waits");
    CHECK(kai_watch_pid_maybe_tagged(w, 330), "an unknown PID is worth parsing");
    kai_watch_process_start(w, 330, 100, T0 + S(699), "C:/Windows/System32/curl.exe");
    CHECK(rec.n == 8 && !strcmp(rec.agent[7], "claude") && !strcmp(rec.host[7], "late.example") &&
          !strcmp(rec.from[7], "process"), "its start event arrives: recorded, with its own lookup's name");
    CHECK(!kai_watch_pid_maybe_tagged(w, 950), "a known untagged PID is not worth parsing");
    kai_watch_connect(w, 340, T0 + S(701), "tcp", "192.0.2.45", 443);
    kai_watch_process_start(w, 340, 950, T0 + S(700), "C:/Windows/System32/curl.exe");
    CHECK(rec.n == 8, "a waiting connect from a process that turns out untagged is dropped");
    kai_watch_connect(w, 350, T0 + S(702), "tcp", "192.0.2.46", 443);
    kai_watch_gc(w, T0 + S(708));
    kai_watch_process_start(w, 350, 100, T0 + S(701), "C:/Windows/System32/curl.exe");
    CHECK(rec.n == 8, "a connect that waited more than 5 s is dropped");
    kai_watch_free(w);
}

static void test_files(const char *home) {
    printf("protected-path filtering\n");
    kai_watch *w = fresh();
    char key[600], src[600], own[600];
    snprintf(key, sizeof key, "%s/.ssh/id_ed25519", home);
    snprintf(src, sizeof src, "%s/proj/main.c", home);
    snprintf(own, sizeof own, "%s/.claude/settings.local.json", home);
    kai_watch_process_start(w, 1000, 4, T0, "C:/Windows/explorer.exe");
    kai_watch_process_start(w, 100, 1000, T0 + S(1), "C:/Users/ann/.local/bin/claude.exe");
    kai_watch_process_start(w, 300, 100, T0 + S(2), "C:/Python311/python.exe");
    kai_watch_process_start(w, 950, 1000, T0 + S(3), "C:/Windows/notepad.exe");

    kai_watch_file(w, 300, T0 + S(4), key);
    CHECK(rec.n == 1 && !strcmp(rec.agent[0], "claude") && !strcmp(rec.path[0], key),
          "a script the agent runs opening a private key is seen");
    kai_watch_file(w, 300, T0 + S(5), src);
    CHECK(rec.n == 1, "a project file is not recorded");
    kai_watch_file(w, 950, T0 + S(6), key);
    CHECK(rec.n == 1, "an untagged process opening a protected file is not recorded");
    char envp[600];
    snprintf(envp, sizeof envp, "%s/proj/.env", home);
    kai_watch_file(w, 100, T0 + S(7), envp);
    CHECK(rec.n == 2, "the agent opening .env is seen");
    kai_watch_free(w);
}

int main(void) {
    char home[700] = "/tmp/kai-watch-test", kh[800];
#ifdef _WIN32
    char tmp[MAX_PATH];
    GetTempPathA(sizeof tmp, tmp);
    snprintf(home, sizeof home, "%skai-watch-%lu", tmp, (unsigned long)GetCurrentProcessId());
    CreateDirectoryA(home, NULL);
    for (char *c = home; *c; c++) if (*c == '\\') *c = '/';
    snprintf(kh, sizeof kh, "%s/kai-home", home);
    _putenv_s("USERPROFILE", home);
    _putenv_s("KAI_HOME", kh);
#else
    snprintf(kh, sizeof kh, "%s/kai-home", home);
    setenv("HOME", home, 1);
    setenv("KAI_HOME", kh, 1);
#endif
    kai_require_sandbox_home();
    char err[256] = "";
    pol = kai_policy_load(NULL, err, sizeof err);
    if (!pol) { printf("policy: %s\n", err); return 1; }
    printf("== Watch unit tests ==\n");
    test_tree();
    test_dns();
    test_files(home);
    kai_policy_free(pol);
    printf("\n%d checks, %d failures\n", checks, fails);
    return fails ? 1 : 0;
}
