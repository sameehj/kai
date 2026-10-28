/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Wire Kai's hook into an agent's settings file, and back it out cleanly.
 * We never clobber the file: we parse it, add our entries, keep a .bak.
 * Every Kai entry carries "_kai": true so uninstall finds exactly ours.
 */
#include "cJSON.h"
#include "internal.h"

#include <stdio.h>
#include <dirent.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static char *read_or_empty(const char *path) {
    size_t n;
    char *s = kai_read_file(path, 8 * 1024 * 1024, &n);
    return s ? s : strdup("");
}

/* A4: atomic - a temp file in the same folder, then rename - so an install
 * killed half-way leaves the old file or the new one, never a torn one. Keeps
 * the existing file's permissions. */
static int write_file(const char *path, const char *data) {
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.kai-tmp.%d", path, (int)getpid());
    struct stat st;
    mode_t mode = stat(path, &st) == 0 ? (st.st_mode & 0777) : 0644;
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    size_t len = strlen(data);
    size_t w = fwrite(data, 1, len, f);
    int ok = w == len && fflush(f) == 0 && fsync(fileno(f)) == 0;
    ok = (fclose(f) == 0) && ok;
    chmod(tmp, mode);
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

/* A4: <file>.kai-bak is the user's ORIGINAL, from before Kai first touched the
 * file - never overwritten; <file>.kai-bak.prev is the state before this
 * install. (One backup, rewritten each time, lost the original on the 2nd.) */
static void backup(const char *path) {
    char *cur = read_or_empty(path);
    if (*cur) {
        char bak[1200], prev[1250];
        snprintf(bak, sizeof bak, "%s.kai-bak", path);
        snprintf(prev, sizeof prev, "%s.kai-bak.prev", path);
        struct stat st;
        if (stat(bak, &st) != 0) write_file(bak, cur);
        write_file(prev, cur);
    }
    free(cur);
}

/* A4 prerequisite: an existing settings file must be valid JSON (an object),
 * or Kai refuses and changes nothing. It used to treat it as empty and write
 * back only its own hooks. */
static int settings_ok(const char *path) {
    char *cur = read_or_empty(path);
    int ok = 1;
    if (*cur) {
        cJSON *o = cJSON_Parse(cur);
        ok = cJSON_IsObject(o);
        cJSON_Delete(o);
    }
    free(cur);
    if (!ok) fprintf(stderr, "%s isn't valid JSON, so Kai changed nothing. Fix it (or move it aside), "
                             "then run kai install again.\n", path);
    return ok;
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
static void strip_legacy_handlers(cJSON *root);

/* Parse an agent settings file, dropping any Kai entries already in it so
 * installing twice never duplicates hooks. */
static cJSON *load_clean(const char *path) {
    char *cur = read_or_empty(path);
    cJSON *root = *cur ? cJSON_Parse(cur) : NULL;
    free(cur);
    if (!root) return cJSON_CreateObject();
    cJSON *clean = without_kai(root);
    cJSON_Delete(root);
    strip_legacy_handlers(clean);
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
    if (!settings_ok(path)) { free(path); return 3; }
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
    ensure_event(hooks, "SessionStart", NULL, exe); /* Item 7: up-front protection/SSH hint */
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

/* A Kai command may survive if a settings editor removed its _kai marker.
 * Remove these handlers only from hook groups, preserving other commands in
 * the group. */
static void strip_legacy_handlers(cJSON *root) {
    cJSON *hooks = cJSON_GetObjectItemCaseSensitive(root, "hooks");
    if (!cJSON_IsObject(hooks)) return;
    for (cJSON *event = hooks->child; event; event = event->next) {
        if (!cJSON_IsArray(event)) continue;
        cJSON *group = event->child;
        while (group) {
            cJSON *next_group = group->next;
            cJSON *handlers = cJSON_GetObjectItemCaseSensitive(group, "hooks");
            if (cJSON_IsArray(handlers)) {
                cJSON *handler = handlers->child;
                while (handler) {
                    cJSON *next_handler = handler->next;
                    cJSON *command = cJSON_GetObjectItemCaseSensitive(handler, "command");
                    if (cJSON_IsString(command) && command->valuestring &&
                        (strstr(command->valuestring, " hook claude") ||
                         strstr(command->valuestring, " hook cursor"))) {
                        cJSON_Delete(cJSON_DetachItemViaPointer(handlers, handler));
                    }
                    handler = next_handler;
                }
                if (!handlers->child) cJSON_Delete(cJSON_DetachItemViaPointer(event, group));
            }
            group = next_group;
        }
    }
}

static int uninstall_file(const char *rel) {
    char *path = kai_expand_home(rel);
    size_t n;
    char *cur = kai_read_file(path, 8 * 1024 * 1024, &n);
    if (!cur) {
        struct stat st;
        int exists = stat(path, &st) == 0;
        if (exists) fprintf(stderr, "Can't read %s; Kai hooks were not removed.\n", path);
        free(path);
        return exists ? 1 : 0;
    }
    if (!*cur) { free(cur); free(path); return 0; }
    cJSON *root = cJSON_Parse(cur);
    free(cur);
    if (!root) {
        fprintf(stderr, "Can't parse %s; Kai hooks were not removed.\n", path);
        free(path);
        return 1;
    }
    cJSON *clean = without_kai(root);
    cJSON_Delete(root);
    strip_legacy_handlers(clean);
    char *out = cJSON_Print(clean);
    int rc = write_file(path, out);
    free(out); cJSON_Delete(clean);
    if (rc == 0) printf("Removed Kai hooks from %s\n", path);
    else fprintf(stderr, "Can't write %s; Kai hooks were not removed.\n", path);
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
    if (!settings_ok(path)) { free(path); return 3; }
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

/* A4: never install an older Kai over a newer one. <kai home>/installed-version
 * records the newest version that installed hooks. */
static int version_guard(void) {
    char p[1200]; snprintf(p, sizeof p, "%s/installed-version", kai_home());
    size_t n = 0; char *v = kai_read_file(p, 256, &n);
    if (v) {
        v[strcspn(v, "\r\n")] = '\0';
        int newer = kai_version_cmp(v, KAI_VERSION) > 0;
        if (newer) fprintf(stderr, "Kai %s is installed; this is the older %s. Kai changed nothing.\n",
                           v, KAI_VERSION);
        free(v);
        if (newer) return 0;
    }
    return 1;
}

static void version_record(void) {
    char p[1200]; snprintf(p, sizeof p, "%s/installed-version", kai_home());
    mkdir(kai_home(), 0700);
    char line[64]; snprintf(line, sizeof line, "%s\n", KAI_VERSION);
    write_file(p, line);
}

int kai_cmd_install(int argc, char **argv) {
    const char *exe = kai_exe_path();
    const char *which = argc > 0 ? argv[0] : "";
    if (!version_guard()) return 3;
    version_record();
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

/* rm -rf for --purge (Kai's own home only). */
static int remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        struct dirent *e;
        while (d && (e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char c[1400]; snprintf(c, sizeof c, "%s/%s", path, e->d_name);
            remove_tree(c);
        }
        if (d) closedir(d);
        return rmdir(path);
    }
    return unlink(path);
}

int kai_cmd_uninstall(int argc, char **argv) {
    const char *which = argc > 0 && strcmp(argv[0], "--purge") ? argv[0] : "all";
    int purge = 0;
    for (int i = 0; i < argc; i++) if (!strcmp(argv[i], "--purge")) purge = 1;
    int rc = 0;
    if (strcmp(which, "claude") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.claude/settings.json");
    if (strcmp(which, "cursor") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_file("~/.cursor/hooks.json");
    if (strcmp(which, "codex") == 0 || strcmp(which, "all") == 0)
        rc |= uninstall_codex();
    if (strcmp(which, "chrome") == 0 || strcmp(which, "browser") == 0 || strcmp(which, "all") == 0)
        rc |= kai_browser_uninstall();
    /* Hooks first (no hook may call a missing binary); the user's policy and
     * logs stay unless they ask for --purge, explicitly. */
    if (purge) {
        if (rc != 0) {
            fprintf(stderr, "Some hooks weren't removed, so Kai's home was kept.\n");
            return rc;
        }
        if (remove_tree(kai_home()) == 0) printf("Removed %s (policy, logs, permissions)\n", kai_home());
        else { fprintf(stderr, "Couldn't remove %s\n", kai_home()); rc = 1; }
    }
    return rc;
}
