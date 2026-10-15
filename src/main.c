/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * The `kai` command. Subcommands:
 *   kai hook claude|cursor|codex   run as an agent hook (reads JSON on stdin)
 *   kai install [claude|cursor|codex|all]
 *   kai uninstall [claude|cursor|codex|all]
 *   kai scan <file>...         report findings in files
 *   kai redact                 clean stdin -> stdout
 *   kai init                   write a default ~/.kai/policy
 *   kai doctor                 check policy + installs
 *   kai status [--json]        doctor, or machine-readable status
 *   kai policy ...             show or edit the policy (see manage.c)
 *   kai gateway [--port N]     local AI gateway (see gateway.c)
 *   kai agent-of <pid>         is this process an agent, or under one?
 *   kai sni                    print the TLS server name from a ClientHello on stdin
 *   kai log tail|verify        audit log
 *   kai version
 */
#include "internal.h"
#include "kai.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int kai_cmd_hook(int argc, char **argv);
int kai_cmd_install(int argc, char **argv);
int kai_cmd_uninstall(int argc, char **argv);
int kai_cmd_status_json(void);
int kai_cmd_policy(int argc, char **argv);

static int cmd_version(void) { printf("kai %s\n", KAI_VERSION); return 0; }

static int cmd_init(void) {
    mkdir(kai_home(), 0700);
    const char *full = kai_policy_file();
    FILE *f = fopen(full, "rb");
    if (f) { fclose(f); printf("Policy already exists at %s\n", full); return 0; }
    f = fopen(full, "wb");
    if (!f) { fprintf(stderr, "Cannot write %s\n", full); return 1; }
    fputs(kai_default_policy(), f);
    fclose(f);
    printf("Wrote default policy to %s\n", full);
    return 0;
}

static int cmd_scan(int argc, char **argv) {
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { fprintf(stderr, "kai: %s\n", err); return 2; }
    int worst = 0;
    if (argc == 0) {
        size_t n;
        char *txt = kai_read_stream(stdin, 16 * 1024 * 1024, &n);
        kai_report rep;
        char *c = kai_scan_text(p, txt ? txt : "", &rep); free(c); free(txt);
        char sum[1024]; kai_report_summary(&rep, sum, sizeof sum);
        printf("(stdin): %s\n", sum);
        if ((int)rep.worst > worst) worst = rep.worst;
    }
    for (int i = 0; i < argc; i++) {
        size_t n;
        char *txt = kai_read_file(argv[i], 16 * 1024 * 1024, &n);
        if (!txt) { printf("%s: (cannot read)\n", argv[i]); continue; }
        kai_report rep;
        char *c = kai_scan_text(p, txt, &rep); free(c); free(txt);
        char sum[1024]; kai_report_summary(&rep, sum, sizeof sum);
        printf("%s: %s\n", argv[i], sum);
        if ((int)rep.worst > worst) worst = rep.worst;
    }
    kai_policy_free(p);
    return worst >= KAI_ACT_REDACT ? 1 : 0;
}

static int cmd_redact(void) {
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { fprintf(stderr, "kai: %s\n", err); return 2; }
    size_t n;
    char *txt = kai_read_stream(stdin, 16 * 1024 * 1024, &n);
    kai_report rep;
    char *clean = kai_scan_text(p, txt ? txt : "", &rep);
    fputs(clean ? clean : "", stdout);
    free(clean); free(txt);
    kai_policy_free(p);
    return 0;
}

static int cmd_doctor(void) {
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { printf("policy: ERROR — %s\n", err); return 1; }
    printf("policy: OK (source: %s)\n", kai_policy_source(p));
    kai_policy_free(p);

    char *cc = kai_expand_home("~/.claude/settings.json");
    char *cu = kai_expand_home("~/.cursor/hooks.json");
    size_t n;
    char *s;
    s = kai_read_file(cc, 4 * 1024 * 1024, &n);
    printf("claude hooks: %s\n", (s && strstr(s, "hook claude")) ? "installed" : "not installed");
    free(s);
    s = kai_read_file(cu, 4 * 1024 * 1024, &n);
    printf("cursor hooks: %s\n", (s && strstr(s, "hook cursor")) ? "installed" : "not installed");
    free(s);
    char *cx = kai_codex_hooks_path();
    s = kai_read_file(cx, 4 * 1024 * 1024, &n);
    printf("codex hooks: %s\n", (s && strstr(s, "hook codex")) ? "installed" : "not installed");
    free(s);
    free(cc); free(cu); free(cx);

    int nl; char verr[256];
    if (kai_audit_verify(NULL, &nl, verr, sizeof verr) == 0)
        printf("audit log: OK (%d records, chain intact)\n", nl);
    else
        printf("audit log: %s\n", nl == 0 ? "empty" : verr);
    return 0;
}

static int cmd_log(int argc, char **argv) {
    const char *sub = argc > 0 ? argv[0] : "tail";
    if (strcmp(sub, "verify") == 0) {
        int nl; char err[256];
        if (kai_audit_verify(NULL, &nl, err, sizeof err) == 0) {
            printf("OK: %d records, chain intact\n", nl);
            return 0;
        }
        printf("FAIL: %s\n", err);
        return 1;
    }
    /* tail */
    size_t n;
    char *txt = kai_read_file(kai_audit_path(), 16 * 1024 * 1024, &n);
    if (!txt) { printf("(no audit log yet)\n"); return 0; }
    fputs(txt, stdout);
    free(txt);
    return 0;
}

static int cmd_gateway(int argc, char **argv) {
    const char *addr = "127.0.0.1";
    int port = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--addr") == 0 && i + 1 < argc) addr = argv[++i];
        else { fprintf(stderr, "usage: kai gateway [--port N] [--addr 127.0.0.1]\n"); return 2; }
    }
    if (port <= 0) {
        char err[256];
        kai_policy *p = kai_policy_load(NULL, err, sizeof err);
        if (!p) { fprintf(stderr, "kai: %s\n", err); return 2; }
        port = p->gateway_port;
        kai_policy_free(p);
    }
    return kai_gateway_run(addr, port);
}

static int cmd_agent_of(int argc, char **argv) {
    if (argc != 1) { fprintf(stderr, "usage: kai agent-of <pid>\n"); return 2; }
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { fprintf(stderr, "kai: %s\n", err); return 2; }
    char name[64];
    int apid;
    int hit = kai_process_agent(p, atoi(argv[0]), name, sizeof name, &apid);
    if (hit) printf("%s (pid %d)\n", name, apid);
    else printf("not an agent\n");
    kai_policy_free(p);
    return hit ? 0 : 1;
}

static int cmd_sni(void) {
    size_t n;
    char *buf = kai_read_stream(stdin, 65536, &n);
    if (!buf) return 2;
    char host[256];
    int rc = kai_tls_sni((const unsigned char *)buf, n, host, sizeof host);
    free(buf);
    if (rc == 1) { printf("%s\n", host); return 0; }
    printf(rc < 0 ? "(incomplete ClientHello)\n" : "(no server name)\n");
    return 1;
}

static void usage(void) {
    fprintf(stderr,
        "kai %s — security layer for AI agents\n\n"
        "Usage:\n"
        "  kai install [claude|cursor|codex|all]   add Kai hooks to an agent\n"
        "  kai uninstall [claude|cursor|codex|all] remove them\n"
        "  kai hook claude|cursor|codex            (run by the agent; reads JSON)\n"
        "  kai scan [file...]                report secrets/terms (stdin if none)\n"
        "  kai redact                        clean stdin -> stdout\n"
        "  kai init                          write ~/.kai/policy\n"
        "  kai doctor                        check policy and installs\n"
        "  kai status [--json]               same as doctor; --json for scripts/app\n"
        "  kai policy [show|set|add|remove]  view or change the policy safely\n"
        "  kai gateway [--port N]            run the local AI gateway\n"
        "  kai agent-of <pid>                is this process an agent, or under one?\n"
        "  kai log [tail|verify]             view / verify the audit log\n"
        "  kai version\n", KAI_VERSION);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    const char *cmd = argv[1];
    int rest = argc - 2;
    char **restv = argv + 2;
    if (strcmp(cmd, "hook") == 0) return kai_cmd_hook(rest, restv);
    if (strcmp(cmd, "install") == 0) return kai_cmd_install(rest, restv);
    if (strcmp(cmd, "uninstall") == 0) return kai_cmd_uninstall(rest, restv);
    if (strcmp(cmd, "scan") == 0) return cmd_scan(rest, restv);
    if (strcmp(cmd, "redact") == 0) return cmd_redact();
    if (strcmp(cmd, "init") == 0) return cmd_init();
    if (strcmp(cmd, "doctor") == 0) return cmd_doctor();
    if (strcmp(cmd, "status") == 0)
        return (rest > 0 && strcmp(restv[0], "--json") == 0) ? kai_cmd_status_json() : cmd_doctor();
    if (strcmp(cmd, "policy") == 0) return kai_cmd_policy(rest, restv);
    if (strcmp(cmd, "gateway") == 0) return cmd_gateway(rest, restv);
    if (strcmp(cmd, "agent-of") == 0) return cmd_agent_of(rest, restv);
    if (strcmp(cmd, "sni") == 0) return cmd_sni();
    if (strcmp(cmd, "log") == 0) return cmd_log(rest, restv);
    if (strcmp(cmd, "version") == 0 || strcmp(cmd, "--version") == 0) return cmd_version();
    if (strcmp(cmd, "help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0) {
        usage(); return 0;
    }
    fprintf(stderr, "kai: unknown command '%s'\n", cmd);
    usage();
    return 2;
}
