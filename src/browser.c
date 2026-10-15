/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * `kai install chrome`: register Kai's native-messaging host with every
 * Chromium-based browser present (Chrome, Brave, Edge, Chromium), so the Kai
 * browser extension can ask `kai` to scan what you type into AI chat sites.
 * The extension itself is loaded from integrations/browser.
 */
#include "internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Each browser's profile root; the host manifest goes in
 * <root>/NativeMessagingHosts/<host>.json. */
static const struct {
    const char *name, *root;
} BROWSERS[] = {
#ifdef __APPLE__
    {"Chrome", "~/Library/Application Support/Google/Chrome"},
    {"Chrome Beta", "~/Library/Application Support/Google/Chrome Beta"},
    {"Brave", "~/Library/Application Support/BraveSoftware/Brave-Browser"},
    {"Edge", "~/Library/Application Support/Microsoft Edge"},
    {"Chromium", "~/Library/Application Support/Chromium"},
    {"Arc", "~/Library/Application Support/Arc/User Data"},
#else
    {"Chrome", "~/.config/google-chrome"},
    {"Chrome Beta", "~/.config/google-chrome-beta"},
    {"Brave", "~/.config/BraveSoftware/Brave-Browser"},
    {"Edge", "~/.config/microsoft-edge"},
    {"Chromium", "~/.config/chromium"},
#endif
};
#define NBROWSERS (sizeof BROWSERS / sizeof BROWSERS[0])

static int is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static char *manifest_path(size_t i) {
    char *root = kai_expand_home(BROWSERS[i].root);
    sb_t b;
    sb_init(&b);
    sb_addf(&b, "%s/NativeMessagingHosts/%s.json", root, KAI_NATIVE_HOST);
    free(root);
    return sb_take(&b);
}

/* The copy the browser loads: ~/.kai/browser-extension. An ordinary folder
 * you can pick in "Load unpacked" (the one inside Kai.app is hidden in the
 * bundle), and inside ~/.kai, which agents can't read or modify. */
static void installed_ext_dir(char *out, size_t n) {
    snprintf(out, n, "%s/browser-extension", kai_home());
}

/* Where the extension ships: next to an installed kai
 * (<prefix>/share/kai/browser), inside Kai.app, or in a source checkout. */
static const char *shipped_ext_dir(void);

const char *kai_browser_ext_dir(void) {
    static char found[1200];
    char mine[1100], mf[1200];
    installed_ext_dir(mine, sizeof mine);
    snprintf(mf, sizeof mf, "%s/manifest.json", mine);
    struct stat st;
    if (stat(mf, &st) == 0) { kai_strlcpy(found, mine, sizeof found); return found; }
    return shipped_ext_dir();
}

static int copy_file(const char *from, const char *to) {
    size_t n;
    char *data = kai_read_file(from, 16 * 1024 * 1024, &n);
    if (!data) return -1;
    FILE *f = fopen(to, "wb");
    int ok = f && fwrite(data, 1, n, f) == n;
    if (f) fclose(f);
    free(data);
    return ok ? 0 : -1;
}

/* Refresh ~/.kai/browser-extension from the shipped copy. Only the files the
 * extension needs, so a test page or stray file never ends up loaded. */
static int sync_extension(const char *src, char *dst, size_t dstlen) {
    installed_ext_dir(dst, dstlen);
    char icons[1200];
    snprintf(icons, sizeof icons, "%s/icons", dst);
    mkdir(kai_home(), 0700);
    mkdir(dst, 0755);
    mkdir(icons, 0755);
    static const char *const FILES[] = {"manifest.json", "background.js", "content.js", "popup.html",
                                        "popup.js", "icons/kai-16.png", "icons/kai-32.png",
                                        "icons/kai-48.png", "icons/kai-128.png"};
    for (size_t i = 0; i < sizeof FILES / sizeof FILES[0]; i++) {
        char a[1300], b[1300];
        snprintf(a, sizeof a, "%s/%s", src, FILES[i]);
        snprintf(b, sizeof b, "%s/%s", dst, FILES[i]);
        if (copy_file(a, b) != 0) {
            fprintf(stderr, "Cannot copy %s\n", a);
            return -1;
        }
    }
    return 0;
}

static const char *shipped_ext_dir(void) {
    static char found[1200];
    if (found[0]) return found;
    char exe[1024];
    kai_strlcpy(exe, kai_exe_path(), sizeof exe);
    char *slash = strrchr(exe, '/');
    if (!slash) return NULL;
    *slash = '\0';
    const char *rel[] = {"/../share/kai/browser", "/browser", "/integrations/browser",
                         "/../../integrations/browser"};
    for (size_t i = 0; i < sizeof rel / sizeof rel[0]; i++) {
        char cand[1300], mf[1400];
        snprintf(cand, sizeof cand, "%s%s", exe, rel[i]);
        snprintf(mf, sizeof mf, "%s/manifest.json", cand);
        struct stat st;
        if (stat(mf, &st) == 0) {
            char *norm = kai_normalize_path(cand, NULL);
            kai_strlcpy(found, norm, sizeof found);
            free(norm);
            return found;
        }
    }
    return NULL;
}

int kai_browser_install(const char *exe) {
    int any = 0, rc = 0;
    for (size_t i = 0; i < NBROWSERS; i++) {
        char *root = kai_expand_home(BROWSERS[i].root);
        int present = is_dir(root);
        if (present) {
            char dir[1200];
            snprintf(dir, sizeof dir, "%s/NativeMessagingHosts", root);
            mkdir(dir, 0755);
            char *path = manifest_path(i);
            FILE *f = fopen(path, "wb");
            if (f) {
                /* JSON by hand: exe is the only variable and is a path we escape. */
                fprintf(f, "{\n  \"name\": \"%s\",\n  \"description\": \"Kai: checks AI chat "
                           "messages for secrets and company data\",\n  \"path\": \"",
                        KAI_NATIVE_HOST);
                for (const char *c = exe; *c; c++) {
                    if (*c == '"' || *c == '\\') fputc('\\', f);
                    fputc(*c, f);
                }
                fprintf(f, "\",\n  \"type\": \"stdio\",\n  \"allowed_origins\": "
                           "[\"chrome-extension://%s/\"]\n}\n",
                        KAI_EXTENSION_ID);
                fclose(f);
                printf("Registered Kai with %s (%s)\n", BROWSERS[i].name, path);
                any = 1;
            } else {
                fprintf(stderr, "Cannot write %s\n", path);
                rc = 1;
            }
            free(path);
        }
        free(root);
    }
    if (!any) {
        fprintf(stderr, "No Chrome, Brave, Edge or Chromium profile found.\n");
        return 1;
    }
    const char *src = shipped_ext_dir();
    char dst[1100];
    if (!src || sync_extension(src, dst, sizeof dst) != 0) {
        fprintf(stderr, "Couldn't find Kai's browser extension files to install.\n");
        return 1;
    }
    if (kai_browser_extension_loaded()) {
        printf("\nThe Kai extension is loaded; it was updated in place.\n"
               "Click the reload arrow on Kai in chrome://extensions to pick up changes.\n");
    } else {
        printf("\nNow load the extension (once):\n"
               "  1. Open chrome://extensions and turn on Developer mode\n"
               "  2. Click \"Load unpacked\" and choose this folder\n"
               "     (in the file dialog press Cmd+Shift+G and paste the path):\n"
               "     %s\n", dst);
    }
    return rc;
}

int kai_browser_uninstall(void) {
    for (size_t i = 0; i < NBROWSERS; i++) {
        char *path = manifest_path(i);
        if (unlink(path) == 0) printf("Removed Kai from %s\n", BROWSERS[i].name);
        free(path);
    }
    return 0;
}

/* Is the Kai extension loaded in any profile of any browser? Chrome records
 * installed extensions by ID in each profile's (Secure) Preferences file. */
int kai_browser_extension_loaded(void) {
    static const char *profiles[] = {"Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4"};
    static const char *files[] = {"Secure Preferences", "Preferences"};
    for (size_t i = 0; i < NBROWSERS; i++) {
        char *root = kai_expand_home(BROWSERS[i].root);
        for (size_t p = 0; p < sizeof profiles / sizeof profiles[0]; p++)
            for (size_t f = 0; f < sizeof files / sizeof files[0]; f++) {
                char path[1400];
                snprintf(path, sizeof path, "%s/%s/%s", root, profiles[p], files[f]);
                size_t n;
                char *s = kai_read_file(path, 32 * 1024 * 1024, &n);
                int hit = s && strstr(s, KAI_EXTENSION_ID);
                free(s);
                if (hit) { free(root); return 1; }
            }
        free(root);
    }
    return 0;
}

/* installed = some browser has the host manifest; detected = some browser exists. */
int kai_browser_installed(int *detected) {
    int on = 0, seen = 0;
    for (size_t i = 0; i < NBROWSERS; i++) {
        char *root = kai_expand_home(BROWSERS[i].root);
        seen |= is_dir(root);
        free(root);
        char *path = manifest_path(i);
        struct stat st;
        on |= stat(path, &st) == 0;
        free(path);
    }
    if (detected) *detected = seen;
    return on;
}
