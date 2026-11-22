/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Is protection actually working right now? "Installed" only means an agent's
 * settings mention Kai. Health runs what the agent would run: for each of
 * Kai's hook commands it checks that the program exists, that the hook fails
 * closed, and that a synthetic request for a path Kai always protects comes
 * back denied. Probes are marked so the hook doesn't record them.
 */
#include "cJSON.h"
#include "internal.h"
#include "platform.h"

#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PROBE_TIMEOUT_MS 5000

/* ---- Can any program the user runs switch Kai off? (Nov 15) ----
 * A program running as the user can delete or replace any file in a folder
 * the user can write to. /usr/local/bin is often the user's (Homebrew), so a
 * kai there can be removed without admin rights. Safe means: the file and
 * every folder above it (as written and as resolved) are owned by root and
 * not group- or world-writable. */
static int one_root_only(const char *p, char *bad, size_t n) {
    struct stat st;
    if (lstat(p, &st) != 0) { snprintf(bad, n, "%s is missing", p); return 0; }
    if (st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH))) {
        struct passwd *owner = getpwuid(st.st_uid);
        snprintf(bad, n, "%s is owned by %s%s", p, owner ? owner->pw_name : "another user",
                 (st.st_mode & S_IWOTH) ? " and anyone can change it"
                 : (st.st_mode & S_IWGRP) ? " and its group can change it" : "");
        return 0;
    }
    return 1;
}

static int chain_root_only(const char *path, char *bad, size_t n) {
    char buf[PATH_MAX];
    kai_strlcpy(buf, path, sizeof buf);
    for (;;) {
        if (!one_root_only(buf, bad, n)) return 0;
        char *s = strrchr(buf, '/');
        if (!s) return 1;
        if (s == buf) { if (buf[1] == '\0') return 1; buf[1] = '\0'; continue; }
        *s = '\0';
    }
}

int kai_path_root_only(const char *path, char *bad, size_t n) {
    if (n) bad[0] = '\0';
    if (!path || path[0] != '/') { snprintf(bad, n, "%s isn't an absolute path", path ? path : "(none)"); return 0; }
    if (!chain_root_only(path, bad, n)) return 0;
    char real[PATH_MAX];
    if (!realpath(path, real)) { snprintf(bad, n, "%s is missing", path); return 0; }
    return strcmp(real, path) == 0 || chain_root_only(real, bad, n);
}

/* The program the installed launcher runs: its K="..." line (an older
 * launcher names /usr/local/bin/kai). */
/* dev/test builds only (release builds ignore them, like KAI_POLICY) */
static const char *test_env(const char *name) {
    const char *v = KAI_ENV_OVERRIDES ? getenv(name) : NULL;
    return v && *v ? v : NULL;
}

const char *kai_launcher_path(void) {
    const char *t = test_env("KAI_TEST_LAUNCHER");
    return t ? t : KAI_HOOK_LAUNCHER;
}

static void launcher_program(char *out, size_t n) {
    const char *tp = test_env("KAI_TEST_PROGRAM");
    kai_strlcpy(out, tp ? tp : KAI_PROGRAM_PATH, n);
    if (tp) return;
    size_t len = 0;
    char *t = kai_read_file(kai_launcher_path(), 1 << 16, &len);
    if (!t) return;
    for (char *l = t; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
        if (strncmp(l, "K=", 2)) continue;
        char *v = l + 2, *e = strchr(v, '\n');
        if (e) *e = '\0';
        size_t vl = strlen(v);
        if (vl >= 2 && (v[0] == '"' || v[0] == '\'') && v[vl - 1] == v[0]) { v[vl - 1] = '\0'; v++; }
        kai_strlcpy(out, v, n);
        break;
    }
    free(t);
}

int kai_install_trusted(char *bad, size_t n) {
    if (!kai_path_root_only(kai_launcher_path(), bad, n)) return 0;
    char prog[PATH_MAX];
    launcher_program(prog, sizeof prog);
    return kai_path_root_only(prog, bad, n);
}

/* Run cmd (POSIX: /bin/sh -c; Windows: as a command line), input on stdin;
 * collect stdout. Returns the exit status (or -1 on timeout / failure to run). */
static int run_probe(const char *cmd, int shell, const char *input, size_t inlen, char *out, size_t outlen,
                     size_t *outgot) {
    return kai_plat_run(cmd, shell, input, inlen, out, outlen, outgot, PROBE_TIMEOUT_MS);
}

/* The program a hook command runs: the text before " hook ". */
/* The program a hook command runs: the part before " hook ", unquoted
 * ('...' with '\'' escapes, as kai install writes it since STEP 2c). */
static void command_exe(const char *cmd, char *exe, size_t n) {
    const char *h = strstr(cmd, " hook ");
    size_t len = h ? (size_t)(h - cmd) : strlen(cmd);
    size_t o = 0;
    int q = 0, win = kai_plat_is_windows();
    size_t i = 0;
    if (win && cmd[0] == '&' && cmd[1] == ' ') i = 2;   /* PowerShell: & '<program>' hook <agent> */
    for (; i < len && o + 1 < n; i++) {
        if (cmd[i] == '\'') {
            if (win && q && i + 1 < len && cmd[i + 1] == '\'') { exe[o++] = cmd[++i]; continue; }   /* PS '' */
            q = !q;
            continue;
        }
        if (!win && !q && cmd[i] == '\\' && i + 1 < len) { exe[o++] = cmd[++i]; continue; }
        exe[o++] = cmd[i];
    }
    exe[o] = '\0';
}

void kai_hook_entry_text(const cJSON *e, char *out, size_t n) {
    if (n) out[0] = '\0';
    const cJSON *c = cJSON_GetObjectItemCaseSensitive(e, "command");
    if (!cJSON_IsString(c) || !c->valuestring) return;
    kai_strlcpy(out, c->valuestring, n);
    const cJSON *args = cJSON_GetObjectItemCaseSensitive(e, "args"), *a;
    cJSON_ArrayForEach(a, args) {
        if (!cJSON_IsString(a)) continue;
        size_t l = strlen(out);
        snprintf(out + l, n - l, " %s", a->valuestring);
    }
}

/* Run a hook entry the way its agent does: an exec-form entry ("args") as a
 * program, anything else through the agent's shell. */
static int run_entry(const cJSON *e, const char *input, size_t inlen, char *out, size_t outlen, size_t *outgot);

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
    const cJSON *probe_e = NULL;
    int found = 0, guarded = 0;   /* guarded: some tool hook fails closed (an earlier Kai) */
    char exe[1100] = "";
    const cJSON *ev;
    cJSON_ArrayForEach(ev, hooks) {
        /* C1: no hook may fail closed. A tool hook that would stop the agent
         * when Kai is missing (an earlier Kai's onFailure, failClosed or exit-2
         * guard) is flagged, and doctor --fix rewrites it. */
        int blocking = !strcmp(ev->string, "PreToolUse") ||
                       !strcmp(ev->string, "beforeReadFile") || !strcmp(ev->string, "beforeShellExecution") ||
                       !strcmp(ev->string, "beforeMCPExecution");
        const cJSON *g;
        cJSON_ArrayForEach(g, ev) {
            /* Claude Code / Codex: groups with a "hooks" list; Cursor: entries */
            const cJSON *list = cJSON_GetObjectItemCaseSensitive(g, "hooks");
            const cJSON *items = cJSON_IsArray(list) ? list : NULL;
            const cJSON *e = items ? items->child : g;
            for (; e; e = items ? e->next : NULL) {
                const cJSON *c = cJSON_GetObjectItemCaseSensitive(e, "command");
                char text[2400];
                kai_hook_entry_text(e, text, sizeof text);
                if (!cJSON_IsString(c) || !strstr(text, needle)) { if (!items) break; continue; }
                found = 1;
                if (!exe[0]) {
                    if (cJSON_IsArray(cJSON_GetObjectItemCaseSensitive(e, "args"))) kai_strlcpy(exe, c->valuestring, sizeof exe);
                    else command_exe(c->valuestring, exe, sizeof exe);
                }
                if (blocking) {
                    const cJSON *of = cJSON_GetObjectItemCaseSensitive(e, "onFailure");
                    int fc = !strcmp(agent, "cursor")
                                 ? cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(e, "failClosed"))
                             : !strcmp(agent, "claude")
                                 ? (cJSON_IsString(of) && !strcmp(of->valuestring, "block")) ||
                                   strstr(c->valuestring, "exit 2") != NULL
                                 : strstr(c->valuestring, "exit 2") != NULL;
                    if (fc) guarded = 1;
                    if (!probe_e && (!strcmp(ev->string, "PreToolUse") || !strcmp(ev->string, "beforeReadFile")))
                        probe_e = e;
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
    /* through the package's launcher: what matters is the kai it runs */
    char prog[PATH_MAX];
    launcher_program(prog, sizeof prog);
    if (!strcmp(exe, KAI_HOOK_LAUNCHER) && executable(exe) && !executable(prog)) {
        set_problem(h, "Kai's program is missing (%s): Kai's checks are off and its settings aren't protected; "
                       "the agent keeps working unchecked until Kai is repaired", prog);
        cJSON_Delete(root);
        return;
    }
    if (!executable(exe)) {
        set_problem(h, guarded ? "Kai's program is missing (%s): the agent is blocked until Kai is repaired "
                                 "(these hooks are from an earlier Kai that stops the agent)"
                               : "Kai's program is missing (%s): Kai's checks are off and its settings aren't "
                                 "protected; the agent keeps working unchecked",
                    exe);
        cJSON_Delete(root);
        return;
    }
    if (!probe_e) {
        set_problem(h, "no hook checks the agent's actions; run kai install %s", agent);
        cJSON_Delete(root);
        return;
    }
    char *in = probe_input(agent);
    char out[4096];
    int rc = run_entry(probe_e, in, strlen(in), out, sizeof out, NULL);
    free(in);
    if (rc != 0 || !strstr(out, "deny")) {
        char why[64];
        snprintf(why, sizeof why, rc < 0 ? "no answer" : "exit %d", rc);
        set_problem(h, "Kai's hook didn't block a test request (%s)", why);
    } else if (guarded) {
        set_problem(h, "hooks are from an earlier Kai and stop the agent if Kai's program goes missing; "
                       "click Repair, or run kai install %s", agent);
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
    const cJSON *found = NULL;
    const cJSON *ev;
    cJSON_ArrayForEach(ev, hooks) {
        if (strcmp(ev->string, "PreToolUse") && strcmp(ev->string, "beforeReadFile")) continue;
        const cJSON *g;
        cJSON_ArrayForEach(g, ev) {
            const cJSON *list = cJSON_GetObjectItemCaseSensitive(g, "hooks");
            const cJSON *items = cJSON_IsArray(list) ? list : NULL;
            for (const cJSON *e = items ? items->child : g; e && !found; e = items ? e->next : NULL) {
                char text[2400];
                kai_hook_entry_text(e, text, sizeof text);
                if (strstr(text, needle)) found = e;
                if (!items) break;
            }
        }
    }
    int rc = found ? run_entry(found, input, strlen(input), out, outlen, NULL) : -1;
    cJSON_Delete(root);
    return rc;
}

static int run_entry(const cJSON *e, const char *input, size_t inlen, char *out, size_t outlen, size_t *outgot) {
    const cJSON *c = cJSON_GetObjectItemCaseSensitive(e, "command");
    const cJSON *args = cJSON_GetObjectItemCaseSensitive(e, "args");
    if (!cJSON_IsString(c)) return -1;
    if (!cJSON_IsArray(args)) return run_probe(c->valuestring, 1, input, inlen, out, outlen, outgot);
    char *av[34];
    int k = 0;
    av[k++] = c->valuestring;
    const cJSON *a;
    cJSON_ArrayForEach(a, args) if (cJSON_IsString(a) && k < 33) av[k++] = a->valuestring;
    av[k] = NULL;
    char *line = kai_plat_quote_argv(av);
    int rc = line ? run_probe(line, 0, input, inlen, out, outlen, outgot) : -1;
    free(line);
    return rc;
}

