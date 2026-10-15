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

/* ----- Claude Code: ~/.claude/settings.json -----
 * hooks.<Event>[] = { matcher, hooks:[{type:command, command:"kai hook claude", _kai:true}] }
 */
static cJSON *claude_hook_entry(const char *matcher, const char *exe) {
    cJSON *group = cJSON_CreateObject();
    if (matcher) cJSON_AddStringToObject(group, "matcher", matcher);
    cJSON *arr = cJSON_CreateArray();
    cJSON *h = cJSON_CreateObject();
    cJSON_AddStringToObject(h, "type", "command");
    char cmd[1300];
    snprintf(cmd, sizeof cmd, "%s hook claude", exe);
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
    cJSON_AddItemToArray(list, claude_hook_entry(matcher, exe));
}

static int install_claude(const char *exe) {
    char *path = kai_expand_home("~/.claude/settings.json");
    mkparents(path);
    backup(path);
    char *cur = read_or_empty(path);
    cJSON *root = *cur ? cJSON_Parse(cur) : cJSON_CreateObject();
    free(cur);
    if (!root) root = cJSON_CreateObject();
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) {
        hooks = cJSON_CreateObject();
        cJSON_AddItemToObject(root, "hooks", hooks);
    }
    ensure_event(hooks, "UserPromptSubmit", NULL, exe);
    ensure_event(hooks, "PreToolUse", "Bash|Read|Edit|Write|Grep|Glob", exe);
    ensure_event(hooks, "PreToolUse", "mcp__.*", exe);
    ensure_event(hooks, "PostToolUse", NULL, exe);
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
    char *cur = read_or_empty(path);
    cJSON *root = *cur ? cJSON_Parse(cur) : cJSON_CreateObject();
    free(cur);
    if (!root) root = cJSON_CreateObject();
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

int kai_cmd_install(int argc, char **argv) {
    const char *exe = kai_exe_path();
    const char *which = argc > 0 ? argv[0] : "";
    if (strcmp(which, "claude") == 0) return install_claude(exe);
    if (strcmp(which, "cursor") == 0) return install_cursor(exe);
    if (strcmp(which, "all") == 0 || !*which) {
        int a = install_claude(exe), b = install_cursor(exe);
        return (a || b) ? 1 : 0;
    }
    fprintf(stderr, "kai install: expected claude | cursor | all\n");
    return 1;
}

int kai_cmd_uninstall(int argc, char **argv) {
    const char *which = argc > 0 ? argv[0] : "all";
    int rc = 0;
    if (strcmp(which, "claude") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.claude/settings.json");
    if (strcmp(which, "cursor") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.cursor/hooks.json");
    return rc;
}
