/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Wire Kai's hook into an agent's settings file, and back it out cleanly.
 * We never clobber the file: we parse it, add our entries, keep a .bak.
 * Every Kai entry carries "_kai": true so uninstall finds exactly ours.
 */
#include "cJSON.h"
#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static char *read_or_empty(const char *path) {
    size_t n;
    char *s = kai_read_file(path, 8 * 1024 * 1024, &n);
    return s ? s : strdup("");
}

static int write_file(const char *path, const char *data) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t len = strlen(data);
    size_t w = fwrite(data, 1, len, f);
    fclose(f);
    return w == len ? 0 : -1;
}

static void backup(const char *path) {
    char *cur = read_or_empty(path);
    if (*cur) {
        char bak[1200];
        snprintf(bak, sizeof bak, "%s.kai-bak", path);
        write_file(bak, cur);
    }
    free(cur);
}

static void mkparents(const char *path) {
    char tmp[1200];
    kai_strlcpy(tmp, path, sizeof tmp);
    char *slash = strrchr(tmp, '/');
    if (!slash) return;
    *slash = '\0';
    char acc[1200] = "";
    char *save = NULL;
    int absolute = tmp[0] == '/';
    for (char *seg = strtok_r(tmp, "/", &save); seg; seg = strtok_r(NULL, "/", &save)) {
        size_t L = strlen(acc);
        snprintf(acc + L, sizeof acc - L, "%s%s", (L || absolute) ? "/" : "", seg);
        mkdir(acc, 0755);
    }
}

static cJSON *without_kai(cJSON *node);

/* Parse an agent settings file, dropping any Kai entries already in it so
 * installing twice never duplicates hooks. */
static cJSON *load_clean(const char *path) {
    char *cur = read_or_empty(path);
    cJSON *root = *cur ? cJSON_Parse(cur) : NULL;
    free(cur);
    if (!root) return cJSON_CreateObject();
    cJSON *clean = without_kai(root);
    cJSON_Delete(root);
    return clean;
}

/* ----- Claude Code: ~/.claude/settings.json -----
 * hooks.<Event>[] = { matcher, hooks:[{type:command, command:"kai hook claude", _kai:true}] }
 */
/* The hook command. A guarded one fails closed: Claude Code and Codex run the
 * action when a hook fails in any way but exit 2, so if Kai's program is
 * missing, crashes or can't answer, the shell turns that into exit 2 (block)
 * with a reason. Only for events where exit 2 means "block" (PreToolUse,
 * UserPromptSubmit): on Stop it would mean "keep going" and trap the agent. */
static void hook_command(char *cmd, size_t n, const char *exe, const char *agent, int guard,
                         const char *settings) {
    if (!guard) {
        snprintf(cmd, n, "%s hook %s", exe, agent);
        return;
    }
    snprintf(cmd, n,
             "%s hook %s || { echo \"Kai couldn't check this: its program is missing or failed. "
             "Reinstall Kai, or remove Kai's entries from %s.\" >&2; exit 2; }",
             exe, agent, settings);
}

static int fails_closed(const char *event) {
    return !strcmp(event, "PreToolUse") || !strcmp(event, "UserPromptSubmit");
}

static cJSON *claude_hook_entry(const char *matcher, const char *exe, int guard) {
    cJSON *group = cJSON_CreateObject();
    if (matcher) cJSON_AddStringToObject(group, "matcher", matcher);
    cJSON *arr = cJSON_CreateArray();
    cJSON *h = cJSON_CreateObject();
    cJSON_AddStringToObject(h, "type", "command");
    char cmd[1600];
    hook_command(cmd, sizeof cmd, exe, "claude", guard, "~/.claude/settings.json");
    cJSON_AddStringToObject(h, "command", cmd);
    cJSON_AddBoolToObject(h, "_kai", 1);
    cJSON_AddItemToArray(arr, h);
    cJSON_AddItemToObject(group, "hooks", arr);
    cJSON_AddBoolToObject(group, "_kai", 1);
    return group;
}

static void ensure_event(cJSON *hooks, const char *event, const char *matcher,
                         const char *exe) {
    cJSON *list = cJSON_GetObjectItemCaseSensitive(hooks, event);
    if (!cJSON_IsArray(list)) {
        list = cJSON_CreateArray();
        cJSON_AddItemToObject(hooks, event, list);
    }
    cJSON_AddItemToArray(list, claude_hook_entry(matcher, exe, fails_closed(event)));
}

static int install_claude(const char *exe) {
    char *path = kai_expand_home("~/.claude/settings.json");
    mkparents(path);
    backup(path);
    cJSON *root = load_clean(path);
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) {
        hooks = cJSON_CreateObject();
        cJSON_AddItemToObject(root, "hooks", hooks);
    }
    ensure_event(hooks, "UserPromptSubmit", NULL, exe);
    ensure_event(hooks, "PreToolUse", "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob|LS", exe);
    ensure_event(hooks, "PreToolUse", "mcp__.*", exe);
    ensure_event(hooks, "PostToolUse", NULL, exe);
    ensure_event(hooks, "Stop", NULL, exe); /* the end of a turn: did the agent give up after a block? */
    char *out = cJSON_Print(root);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(root);
    if (rc == 0) printf("Installed Kai hooks into %s (backup: %s.kai-bak)\n", path, path);
    else fprintf(stderr, "Failed to write %s\n", path);
    free(path);
    return rc;
}

/* ----- Cursor: ~/.cursor/hooks.json -----
 * { version:1, hooks:{ <event>:[ {command:"kai hook cursor", failClosed:true, _kai:true} ] } }
 */
static cJSON *cursor_hook_entry(const char *exe, const char *matcher) {
    cJSON *h = cJSON_CreateObject();
    char cmd[1300];
    snprintf(cmd, sizeof cmd, "%s hook cursor", exe);
    cJSON_AddStringToObject(h, "command", cmd);
    cJSON_AddBoolToObject(h, "failClosed", 1);
    if (matcher) cJSON_AddStringToObject(h, "matcher", matcher);
    cJSON_AddBoolToObject(h, "_kai", 1);
    return h;
}

static void cursor_event(cJSON *hooks, const char *event, const char *exe,
                         const char *matcher) {
    cJSON *list = cJSON_GetObjectItemCaseSensitive(hooks, event);
    if (!cJSON_IsArray(list)) {
        list = cJSON_CreateArray();
        cJSON_AddItemToObject(hooks, event, list);
    }
    cJSON_AddItemToArray(list, cursor_hook_entry(exe, matcher));
}

static int install_cursor(const char *exe) {
    char *path = kai_expand_home("~/.cursor/hooks.json");
    mkparents(path);
    backup(path);
    cJSON *root = load_clean(path);
    if (!cJSON_GetObjectItemCaseSensitive(root, "version"))
        cJSON_AddNumberToObject(root, "version", 1);
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) {
        hooks = cJSON_CreateObject();
        cJSON_AddItemToObject(root, "hooks", hooks);
    }
    cursor_event(hooks, "beforeReadFile", exe, NULL);
    cursor_event(hooks, "beforeShellExecution", exe, NULL);
    cursor_event(hooks, "beforeMCPExecution", exe, NULL);
    cursor_event(hooks, "beforeSubmitPrompt", exe, NULL);
    char *out = cJSON_Print(root);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(root);
    if (rc == 0) printf("Installed Kai hooks into %s (backup: %s.kai-bak)\n", path, path);
    else fprintf(stderr, "Failed to write %s\n", path);
    free(path);
    return rc;
}

/* Remove any array element (at any depth under "hooks") whose object has
 * "_kai": true. Then drop empty arrays. */
static void strip_kai(cJSON *node) {
    if (!node) return;
    if (cJSON_IsArray(node)) {
        cJSON *c = node->child;
        while (c) {
            cJSON *next = c->next;
            cJSON *flag = cJSON_GetObjectItemCaseSensitive(c, "_kai");
            if (cJSON_IsTrue(flag)) cJSON_DeleteItemFromArray(
                node, cJSON_GetArrayItem(node, 0) == c ? 0 : -1);
            c = next;
        }
        /* simpler: rebuild without _kai items */
    }
}

/* robust removal: rebuild arrays without _kai entries */
static cJSON *without_kai(cJSON *node) {
    if (cJSON_IsArray(node)) {
        cJSON *out = cJSON_CreateArray();
        for (cJSON *c = node->child; c; c = c->next) {
            cJSON *flag = cJSON_GetObjectItemCaseSensitive(c, "_kai");
            if (cJSON_IsTrue(flag)) continue;
            cJSON_AddItemToArray(out, without_kai(c));
        }
        return out;
    }
    if (cJSON_IsObject(node)) {
        cJSON *out = cJSON_CreateObject();
        for (cJSON *c = node->child; c; c = c->next)
            cJSON_AddItemToObject(out, c->string, without_kai(c));
        return out;
    }
    return cJSON_Duplicate(node, 1);
}

static int uninstall_file(const char *rel) {
    char *path = kai_expand_home(rel);
    char *cur = read_or_empty(path);
    if (!*cur) { free(cur); free(path); return 0; }
    cJSON *root = cJSON_Parse(cur);
    free(cur);
    if (!root) { free(path); return 0; }
    cJSON *clean = without_kai(root);
    cJSON_Delete(root);
    char *out = cJSON_Print(clean);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(clean);
    if (rc == 0) printf("Removed Kai hooks from %s\n", path);
    free(path);
    (void)strip_kai;
    return rc;
}

/* ----- Codex: $CODEX_HOME/hooks.json (default ~/.codex/hooks.json) -----
 * Same shape as Claude Code's "hooks" block:
 *   { "hooks": { "<Event>": [ { "hooks": [ {type:command, command:"kai hook codex"} ] } ] } }
 * Codex validates its config strictly, so Kai adds no "_kai" marker here; its
 * entries are recognised by their command (" hook codex"). Codex asks the user
 * to review and trust new hooks before it runs them. */

char *kai_codex_home(void) {
    const char *env = getenv("CODEX_HOME");
    if (env && *env) return kai_expand_home(env);
    return kai_expand_home("~/.codex");
}

char *kai_codex_hooks_path(void) {
    char *home = kai_codex_home();
    sb_t b;
    sb_init(&b);
    sb_adds(&b, home);
    sb_adds(&b, "/hooks.json");
    free(home);
    return sb_take(&b);
}

static int is_kai_codex_handler(const cJSON *h) {
    const cJSON *c = cJSON_GetObjectItemCaseSensitive(h, "command");
    return cJSON_IsString(c) && c->valuestring && strstr(c->valuestring, " hook codex");
}

/* Drop Kai's handlers from every event; drop groups and events left empty. */
static void strip_codex(cJSON *root) {
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) return;
    cJSON *ev = hooks->child;
    while (ev) {
        cJSON *next_ev = ev->next;
        if (cJSON_IsArray(ev)) {
            cJSON *g = ev->child;
            while (g) {
                cJSON *next_g = g->next;
                cJSON *hs = cJSON_GetObjectItemCaseSensitive(g, "hooks");
                if (cJSON_IsArray(hs)) {
                    cJSON *h = hs->child;
                    while (h) {
                        cJSON *next_h = h->next;
                        if (is_kai_codex_handler(h)) cJSON_Delete(cJSON_DetachItemViaPointer(hs, h));
                        h = next_h;
                    }
                    if (!hs->child) cJSON_Delete(cJSON_DetachItemViaPointer(ev, g));
                }
                g = next_g;
            }
            if (!ev->child) cJSON_Delete(cJSON_DetachItemViaPointer(hooks, ev));
        }
        ev = next_ev;
    }
    if (!hooks->child) cJSON_Delete(cJSON_DetachItemViaPointer(root, hooks));
}

static cJSON *load_json_object(const char *path) {
    char *cur = read_or_empty(path);
    cJSON *root = *cur ? cJSON_Parse(cur) : NULL;
    free(cur);
    if (!cJSON_IsObject(root)) { cJSON_Delete(root); root = cJSON_CreateObject(); }
    return root;
}

static int install_codex(const char *exe) {
    char *path = kai_codex_hooks_path();
    mkparents(path);
    backup(path);
    cJSON *root = load_json_object(path);
    strip_codex(root);
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) {
        hooks = cJSON_CreateObject();
        cJSON_AddItemToObject(root, "hooks", hooks);
    }
    /* No matcher: Kai sees every tool (shell, apply_patch, MCP) and decides itself. */
    const char *events[] = {"PreToolUse", "PostToolUse", "UserPromptSubmit"};
    char cmd[1600];
    for (size_t i = 0; i < sizeof events / sizeof events[0]; i++) {
        hook_command(cmd, sizeof cmd, exe, "codex", fails_closed(events[i]), path);
        cJSON *list = cJSON_GetObjectItemCaseSensitive(hooks, events[i]);
        if (!cJSON_IsArray(list)) {
            list = cJSON_CreateArray();
            cJSON_AddItemToObject(hooks, events[i], list);
        }
        cJSON *group = cJSON_CreateObject();
        cJSON *arr = cJSON_AddArrayToObject(group, "hooks");
        cJSON *h = cJSON_CreateObject();
        cJSON_AddStringToObject(h, "type", "command");
        cJSON_AddStringToObject(h, "command", cmd);
        cJSON_AddItemToArray(arr, h);
        cJSON_AddItemToArray(list, group);
    }
    char *out = cJSON_Print(root);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(root);
    if (rc == 0) {
        printf("Installed Kai hooks into %s (backup: %s.kai-bak)\n", path, path);
        printf("Codex asks you to review new hooks: open Codex and trust Kai's hooks once.\n");
    } else {
        fprintf(stderr, "Failed to write %s\n", path);
    }
    free(path);
    return rc;
}

static int uninstall_codex(void) {
    char *path = kai_codex_hooks_path();
    char *cur = read_or_empty(path);
    if (!*cur) { free(cur); free(path); return 0; }
    cJSON *root = cJSON_Parse(cur);
    free(cur);
    if (!root) { free(path); return 0; }
    strip_codex(root);
    char *out = cJSON_Print(root);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(root);
    if (rc == 0) printf("Removed Kai hooks from %s\n", path);
    free(path);
    return rc;
}

/* Is Codex used on this machine (its home folder exists)? */
static int codex_present(void) {
    char *home = kai_codex_home();
    struct stat st;
    int ok = stat(home, &st) == 0 && S_ISDIR(st.st_mode);
    free(home);
    return ok;
}

int kai_cmd_install(int argc, char **argv) {
    const char *exe = kai_exe_path();
    const char *which = argc > 0 ? argv[0] : "";
    if (strcmp(which, "claude") == 0) return install_claude(exe);
    if (strcmp(which, "cursor") == 0) return install_cursor(exe);
    if (strcmp(which, "codex") == 0) return install_codex(exe);
    if (strcmp(which, "chrome") == 0 || strcmp(which, "browser") == 0) return kai_browser_install(exe);
    if (strcmp(which, "all") == 0 || !*which) {
        int a = install_claude(exe), b = install_cursor(exe);
        int c = codex_present() ? install_codex(exe) : 0;
        return (a || b || c) ? 1 : 0;
    }
    fprintf(stderr, "kai install: expected claude | cursor | codex | chrome | all\n");
    return 1;
}

int kai_cmd_uninstall(int argc, char **argv) {
    const char *which = argc > 0 ? argv[0] : "all";
    int rc = 0;
    if (strcmp(which, "claude") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.claude/settings.json");
    if (strcmp(which, "cursor") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.cursor/hooks.json");
    if (strcmp(which, "codex") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_codex();
    if (strcmp(which, "chrome") == 0 || strcmp(which, "browser") == 0 || strcmp(which, "all") == 0)
        rc |= kai_browser_uninstall();
    return rc;
}
