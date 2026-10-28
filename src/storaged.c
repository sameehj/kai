/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * `kai storaged`: a development aid for the storage wall.
 *
 * The real wall (deny an agent's open() of a protected file) needs a macOS
 * Endpoint Security client, which needs Apple's ES entitlement. Until that
 * ships, this lets you SEE the decisions the wall would make, using the
 * built-in `eslogger`, which reports open() events without the entitlement
 * (it only needs root — it can observe, never block):
 *
 *     sudo eslogger open | kai storaged
 *
 * For each open by an AI agent process, it prints the decision
 * kai_storage_open_allowed would return under your current policy, and (with
 * --log) records would-block decisions in the audit log. It never blocks
 * anything: it is a monitor, so it is safe to leave running.
 *
 * It reads eslogger's JSON, one event per line, and uses two fields:
 *   .process.audit_token.pid       (the opening process)
 *   .event.open.file.path          (the file)
 * Different eslogger versions nest the pid slightly differently, so a few
 * shapes are accepted.
 */
#include "cJSON.h"
#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int json_pid(const cJSON *proc) {
    if (!proc) return 0;
    const cJSON *at = cJSON_GetObjectItemCaseSensitive(proc, "audit_token");
    const cJSON *pid = cJSON_GetObjectItemCaseSensitive(at, "pid");
    if (cJSON_IsNumber(pid)) return pid->valueint;
    pid = cJSON_GetObjectItemCaseSensitive(proc, "pid");
    if (cJSON_IsNumber(pid)) return pid->valueint;
    /* some versions give the audit token as an 8-element array; pid is [5] */
    if (cJSON_IsArray(at) && cJSON_GetArraySize(at) >= 6) {
        const cJSON *e = cJSON_GetArrayItem(at, 5);
        if (cJSON_IsNumber(e)) return e->valueint;
    }
    return 0;
}

static const char *json_path(const cJSON *root) {
    const cJSON *ev = cJSON_GetObjectItemCaseSensitive(root, "event");
    const cJSON *open = cJSON_GetObjectItemCaseSensitive(ev, "open");
    const cJSON *file = cJSON_GetObjectItemCaseSensitive(open, "file");
    const cJSON *path = cJSON_GetObjectItemCaseSensitive(file, "path");
    return cJSON_IsString(path) ? path->valuestring : NULL;
}

int kai_cmd_storaged(int argc, char **argv) {
    int do_log = 0, run = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--log")) do_log = 1;
        else if (!strcmp(argv[i], "--run")) run = 1;
    }
    /* --run launches eslogger itself (one command, but needs root), instead of
     * reading its JSON on stdin. eslogger can observe file opens without the ES
     * entitlement; it just can't block, which is why this is a monitor. */
    if (run) {
        if (geteuid() != 0) {
            fprintf(stderr, "kai storaged --run needs root (eslogger does): sudo kai storaged --run\n");
            return 1;
        }
        FILE *es = popen("eslogger open 2>/dev/null", "r");
        if (!es) { fprintf(stderr, "kai storaged: could not start eslogger\n"); return 1; }
        if (dup2(fileno(es), 0) < 0) { pclose(es); return 1; }
    }

    char err[256] = "";
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) { fprintf(stderr, "kai storaged: policy error: %s\n", err); return 1; }
    kai_storage_mode mode = kai_policy_storage_mode(p);
    fprintf(stderr, "kai storaged: watching agent file opens (storage=%s). "
                    "This is a monitor; it never blocks.\n",
            mode == KAI_STORAGE_BLOCK ? "block" : mode == KAI_STORAGE_LOG ? "log" : "off");
    if (mode == KAI_STORAGE_OFF)
        fprintf(stderr, "kai storaged: storage is off; showing what block mode would do.\n");

    char *line = NULL;
    size_t cap = 0;
    ssize_t n;
    long agent_opens = 0, would_block = 0;
    while ((n = getline(&line, &cap, stdin)) > 0) {
        cJSON *root = cJSON_Parse(line);
        if (!root) continue;
        int pid = json_pid(cJSON_GetObjectItemCaseSensitive(root, "process"));
        const char *path = json_path(root);
        if (pid > 1 && path) {
            char name[64] = "";
            if (kai_process_agent(p, pid, name, sizeof name, NULL)) {
                agent_opens++;
                char why[256] = "";
                /* preview block mode's answer regardless of the current mode,
                 * so "off" still shows what turning it on would do */
                int allow = kai_path_protected(p, path, NULL, why, sizeof why) ? 0 : 1;
                if (!allow) {
                    would_block++;
                    printf("WOULD BLOCK  %-12s pid %d  %s  (%s)\n", name, pid, path, why);
                    if (do_log) {
                        kai_audit_entry e = {"storage", "open", "would-block", why,
                                             "agent would be denied this file", "open",
                                             (char *)path, NULL, NULL, NULL, NULL};
                        kai_audit_write(&e);
                    }
                }
            }
        }
        cJSON_Delete(root);
    }
    free(line);
    kai_policy_free(p);
    fprintf(stderr, "kai storaged: %ld agent opens seen, %ld would be blocked.\n",
            agent_opens, would_block);
    return 0;
}
