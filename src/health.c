/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Is protection actually working right now? "Installed" only means an agent's
 * settings mention Kai. Health runs what the agent would run: for each of
 * Kai's hook commands it checks that the program exists, that the hook fails
 * closed, and that a synthetic request for a path Kai always protects comes
 * back denied. For the browser it starts the native host the way Chrome does
 * and pings it. Probes are marked so the hook doesn't record them.
 */
#include "cJSON.h"
#include "internal.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PROBE_TIMEOUT_MS 5000

/* Run cmd with /bin/sh, input on stdin; collect stdout. Returns the exit
 * status (or -1 on timeout / failure to run). */
static int run_probe(const char *cmd, const char *input, size_t inlen, char *out, size_t outlen,
                     size_t *outgot) {
    if (outlen) out[0] = '\0';
    if (outgot) *outgot = 0;
    int in[2], o[2];
    if (pipe(in) != 0) return -1;
    if (pipe(o) != 0) { close(in[0]); close(in[1]); return -1; }
    pid_t pid = fork();
    if (pid < 0) { close(in[0]); close(in[1]); close(o[0]); close(o[1]); return -1; }
    if (pid == 0) {
        dup2(in[0], 0);
        dup2(o[1], 1);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, 2);
        close(in[0]); close(in[1]); close(o[0]); close(o[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(in[0]);
    close(o[1]);
    signal(SIGPIPE, SIG_IGN);
    ssize_t w = write(in[1], input, inlen);
    (void)w;
    close(in[1]);
    size_t got = 0;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        struct timespec t;
        clock_gettime(CLOCK_MONOTONIC, &t);
        long left = PROBE_TIMEOUT_MS - ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000);
        if (left <= 0) break;
        struct pollfd pf = {o[0], POLLIN, 0};
        int r = poll(&pf, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        char buf[1024];
        ssize_t n = read(o[0], buf, sizeof buf);
        if (n <= 0) break;
        if (got + 1 < outlen) {
            size_t take = (size_t)n < outlen - 1 - got ? (size_t)n : outlen - 1 - got;
            memcpy(out + got, buf, take);
            got += take;
            out[got] = '\0';
        }
    }
    close(o[0]);
    if (outgot) *outgot = got;
    int status = 0;
    for (int i = 0; i < 50; i++) { /* give it up to 0.5 s to exit after closing stdout */
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        usleep(10000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return -1;
}

/* The program a hook command runs: the text before " hook ". */
static void command_exe(const char *cmd, char *exe, size_t n) {
    const char *h = strstr(cmd, " hook ");
    size_t len = h ? (size_t)(h - cmd) : strlen(cmd);
    if (len >= n) len = n - 1;
    memcpy(exe, cmd, len);
    exe[len] = '\0';
}

static int executable(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode) && access(path, X_OK) == 0;
}

static void set_problem(kai_health *h, const char *fmt, const char *arg) {
    h->ok = 0;
    snprintf(h->problem, sizeof h->problem, fmt, arg ? arg : "");
}

/* A request for a file Kai always protects (its own audit log): any working
 * hook must deny it, whatever the user's policy says. */
static char *probe_input(const char *agent) {
    char path[1200];
    snprintf(path, sizeof path, "%s/audit.log", kai_home());
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "kai_health_probe", 1);
    if (!strcmp(agent, "cursor")) {
        cJSON_AddStringToObject(o, "hook_event_name", "beforeReadFile");
        cJSON_AddStringToObject(o, "file_path", path);
    } else {
        cJSON_AddStringToObject(o, "hook_event_name", "PreToolUse");
        cJSON_AddStringToObject(o, "cwd", "/");
        cJSON_AddStringToObject(o, "tool_name", "Read");
        cJSON *ti = cJSON_AddObjectToObject(o, "tool_input");
        cJSON_AddStringToObject(ti, "file_path", path);
    }
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

void kai_health_agent(const char *agent, const char *config, kai_health *h) {
    memset(h, 0, sizeof *h);
    h->ok = 1;
    size_t n;
    char *path = kai_expand_home(config);
    char *txt = kai_read_file(path, 4 * 1024 * 1024, &n);
    free(path);
    cJSON *root = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    if (!root) { set_problem(h, "can't read %s", config); return; }

    char needle[32];
    snprintf(needle, sizeof needle, " hook %s", agent);
    const cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    const char *probe_cmd = NULL;
    int found = 0, guarded = 1;
    char exe[1100] = "";
    const cJSON *ev;
    cJSON_ArrayForEach(ev, hooks) {
        int blocking = !strcmp(ev->string, "PreToolUse") || !strcmp(ev->string, "UserPromptSubmit") ||
                       !strcmp(ev->string, "beforeReadFile") || !strcmp(ev->string, "beforeShellExecution") ||
                       !strcmp(ev->string, "beforeSubmitPrompt") || !strcmp(ev->string, "beforeMCPExecution");
        const cJSON *g;
        cJSON_ArrayForEach(g, ev) {
            /* Claude Code / Codex: groups with a "hooks" list; Cursor: entries */
            const cJSON *list = cJSON_GetObjectItemCaseSensitive(g, "hooks");
            const cJSON *items = cJSON_IsArray(list) ? list : NULL;
            const cJSON *e = items ? items->child : g;
            for (; e; e = items ? e->next : NULL) {
                const cJSON *c = cJSON_GetObjectItemCaseSensitive(e, "command");
                if (!cJSON_IsString(c) || !strstr(c->valuestring, needle)) { if (!items) break; continue; }
                found = 1;
                if (!exe[0]) command_exe(c->valuestring, exe, sizeof exe);
                if (blocking) {
                    int fc = !strcmp(agent, "cursor")
                                 ? cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(e, "failClosed"))
                                 : strstr(c->valuestring, "exit 2") != NULL;
                    if (!fc) guarded = 0;
                    if (!probe_cmd && (!strcmp(ev->string, "PreToolUse") || !strcmp(ev->string, "beforeReadFile")))
                        probe_cmd = c->valuestring;
                }
                if (!items) break;
            }
        }
    }
    if (!found) {
        h->ok = 0;
        h->problem[0] = '\0'; /* not installed: not a health problem */
        cJSON_Delete(root);
        return;
    }
    if (!executable(exe)) {
        set_problem(h, guarded ? "Kai's program is missing (%s): the agent is blocked until Kai is reinstalled"
                               : "Kai's program is missing (%s): the agent runs unchecked",
                    exe);
        cJSON_Delete(root);
        return;
    }
    if (!probe_cmd) {
        set_problem(h, "no hook checks the agent's actions; run kai install %s", agent);
        cJSON_Delete(root);
        return;
    }
    char *in = probe_input(agent);
    char out[4096];
    int rc = run_probe(probe_cmd, in, strlen(in), out, sizeof out, NULL);
    free(in);
    if (rc != 0 || !strstr(out, "deny")) {
        char why[64];
        snprintf(why, sizeof why, rc < 0 ? "no answer" : "exit %d", rc);
        set_problem(h, "Kai's hook didn't block a test request (%s)", why);
    } else if (!guarded) {
        set_problem(h, "hooks are from an older Kai and let the agent run unchecked if Kai fails; "
                       "run kai install %s or reopen the app", agent);
    }
    cJSON_Delete(root);
}

/* Spec v2.1 A.4: run the agent's installed blocking hook command (exactly as
 * the agent would) with `input` on stdin. Returns its exit status, or -1 if
 * no Kai hook command is installed for the agent or it couldn't run. */
int kai_health_run_hook(const char *agent, const char *config, const char *input, char *out, size_t outlen) {
    if (outlen) out[0] = '\0';
    size_t n;
    char *path = kai_expand_home(config);
    char *txt = kai_read_file(path, 4 * 1024 * 1024, &n);
    free(path);
    cJSON *root = txt ? cJSON_Parse(txt) : NULL;
    free(txt);
    if (!root) return -1;
    char needle[32];
    snprintf(needle, sizeof needle, " hook %s", agent);
    const cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    char cmd[2048] = "";
    const cJSON *ev;
    cJSON_ArrayForEach(ev, hooks) {
        if (strcmp(ev->string, "PreToolUse") && strcmp(ev->string, "beforeReadFile")) continue;
        const cJSON *g;
        cJSON_ArrayForEach(g, ev) {
            const cJSON *list = cJSON_GetObjectItemCaseSensitive(g, "hooks");
            const cJSON *items = cJSON_IsArray(list) ? list : NULL;
            for (const cJSON *e = items ? items->child : g; e && !cmd[0]; e = items ? e->next : NULL) {
                const cJSON *c = cJSON_GetObjectItemCaseSensitive(e, "command");
                if (cJSON_IsString(c) && strstr(c->valuestring, needle)) kai_strlcpy(cmd, c->valuestring, sizeof cmd);
                if (!items) break;
            }
        }
    }
    cJSON_Delete(root);
    if (!cmd[0]) return -1;
    return run_probe(cmd, input, strlen(input), out, outlen, NULL);
}

/* Native messaging: 4-byte native-endian length, then JSON. */
void kai_health_chrome(const char *exe, kai_health *h) {
    memset(h, 0, sizeof *h);
    h->ok = 1;
    if (!exe || !executable(exe)) { set_problem(h, "Kai's program is missing (%s)", exe); return; }
    char cmd[1400];
    snprintf(cmd, sizeof cmd, "'%s' chrome-extension://%s/", exe, KAI_EXTENSION_ID);
    if (strchr(exe, '\'')) { set_problem(h, "unusual program path (%s)", exe); return; }
    const char *msg = "{\"type\":\"ping\"}";
    unsigned int len = (unsigned int)strlen(msg);
    char in[64];
    memcpy(in, &len, 4);
    memcpy(in + 4, msg, len);
    char out[512];
    size_t got = 0;
    run_probe(cmd, in, 4 + len, out, sizeof out, &got);
    if (got < 4 || !memmem(out + 4, got - 4, "\"ok\":true", 9))
        set_problem(h, "the browser helper didn't answer (%s)", exe);
}
