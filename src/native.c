/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Native-messaging host for the Kai browser extension (integrations/browser).
 * Chrome (and Brave, Edge, Chromium) start `kai` with the extension's origin
 * as the first argument and talk over stdin/stdout: each message is a 32-bit
 * length in native byte order followed by that many bytes of JSON.
 *
 * Requests from the extension:
 *   {"type":"ping"}
 *       -> {"ok":true,"version":"0.1.0"}
 *   {"type":"scan","text":"...","site":"chatgpt.com"}
 *       -> {"ok":true,"worst":"none|warn|replace|redact|block","cleaned":"...",
 *           "summary":"...","can_override":true}
 *   {"type":"decision","site":"...","action":"redacted|sent_anyway|blocked|cancelled",
 *    "summary":"..."}
 *       -> {"ok":true}   (recorded in the audit log; "not_a_secret" too, as a
 *                         false-positive note: it changes no policy)
 *   {"type":"status","sites":[{"site":"claude.ai","open_tabs":2,
 *                              "redactions":3,"overrides":1}, ...]}
 *       -> {"ok":true}   (feeds the "AI chats" section; site only, no URL/text)
 *
 * The host only scans, logs, and records which chat SITES are open (never a URL
 * or any chat text). It cannot change the policy or install anything, so a
 * malicious page that reaches the extension gains nothing.
 */
#include "cJSON.h"
#include "internal.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define MAX_IN (4 * 1024 * 1024)   /* Chrome sends at most 4 GB; we accept 4 MB */
#define MAX_OUT (1024 * 1024 - 64) /* Chrome accepts at most 1 MB from a host */

static int read_msg(char **out) {
    uint32_t len;
    if (fread(&len, sizeof len, 1, stdin) != 1) return -1; /* browser closed the pipe */
    if (len > MAX_IN) return -2;
    char *buf = malloc((size_t)len + 1);
    if (!buf) return -2;
    if (len && fread(buf, 1, len, stdin) != len) { free(buf); return -1; }
    buf[len] = '\0';
    *out = buf;
    return 0;
}

static void write_msg(cJSON *o) {
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!s) return;
    uint32_t len = (uint32_t)strlen(s);
    if (len > MAX_OUT) { /* too big to send back: report instead of truncating JSON */
        free(s);
        cJSON *e = cJSON_CreateObject();
        cJSON_AddBoolToObject(e, "ok", 0);
        cJSON_AddStringToObject(e, "error", "text too large for Kai to return");
        s = cJSON_PrintUnformatted(e);
        cJSON_Delete(e);
        len = (uint32_t)strlen(s);
    }
    fwrite(&len, sizeof len, 1, stdout);
    fwrite(s, 1, len, stdout);
    fflush(stdout);
    free(s);
}

static cJSON *error_reply(const char *msg) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", 0);
    cJSON_AddStringToObject(o, "error", msg);
    return o;
}

/* The policy, reloaded when the file changes so edits apply without
 * restarting the browser. */
static kai_policy *policy;
static time_t policy_mtime;
static char policy_err[256];

static kai_policy *current_policy(void) {
    struct stat st;
    time_t m = stat(kai_policy_file(), &st) == 0 ? st.st_mtime : 0;
    if (policy && m == policy_mtime) return policy;
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) {
        kai_strlcpy(policy_err, err, sizeof policy_err);
        return NULL; /* keep failing closed until the policy is fixed */
    }
    kai_policy_free(policy);
    policy = p;
    policy_mtime = m;
    policy_err[0] = '\0';
    return policy;
}

static const char *site_of(const cJSON *req) {
    const cJSON *s = cJSON_GetObjectItemCaseSensitive(req, "site");
    return (cJSON_IsString(s) && s->valuestring && *s->valuestring) ? s->valuestring : "browser";
}

static cJSON *handle_scan(const cJSON *req) {
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(req, "text");
    if (!cJSON_IsString(t) || !t->valuestring) return error_reply("missing text");
    kai_policy *p = current_policy();
    if (!p) {
        /* Broken policy: tell the extension to hold the message. */
        cJSON *o = cJSON_CreateObject();
        cJSON_AddBoolToObject(o, "ok", 1);
        cJSON_AddStringToObject(o, "worst", "block");
        cJSON_AddStringToObject(o, "cleaned", t->valuestring);
        char msg[320];
        snprintf(msg, sizeof msg, "Kai policy error: %s", policy_err);
        cJSON_AddStringToObject(o, "summary", msg);
        cJSON_AddBoolToObject(o, "can_override", 0);
        return o;
    }
    kai_report rep;
    char *clean = kai_scan_text(p, t->valuestring, &rep);
    char summary[1024] = "";
    if (rep.nhits) kai_report_summary(&rep, summary, sizeof summary);

    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", 1);
    cJSON_AddStringToObject(o, "worst", rep.nhits ? kai_action_name(rep.worst) : "none");
    cJSON_AddStringToObject(o, "cleaned", clean ? clean : t->valuestring);
    cJSON_AddStringToObject(o, "summary", summary);
    /* Policy "block" (a block term, or secrets set to block) can't be
     * overridden from the page; redact/replace/warn can, and is logged. */
    cJSON_AddBoolToObject(o, "can_override", rep.worst < KAI_ACT_BLOCK);
    cJSON_AddBoolToObject(o, "skipped", rep.skipped);
    cJSON *hits = cJSON_AddArrayToObject(o, "hits");
    for (int i = 0; i < rep.nhits; i++) {
        cJSON *h = cJSON_CreateObject();
        cJSON_AddStringToObject(h, "rule", rep.hits[i].rule);
        cJSON_AddStringToObject(h, "action", kai_action_name(rep.hits[i].action));
        cJSON_AddNumberToObject(h, "count", rep.hits[i].count);
        cJSON_AddItemToArray(hits, h);
    }
    free(clean);
    return o;
}

static cJSON *handle_decision(const cJSON *req) {
    const cJSON *a = cJSON_GetObjectItemCaseSensitive(req, "action");
    const cJSON *s = cJSON_GetObjectItemCaseSensitive(req, "summary");
    const char *action = cJSON_IsString(a) ? a->valuestring : "";
    const char *decision =
        strcmp(action, "blocked") == 0 || strcmp(action, "cancelled") == 0 ? "block"
        : strcmp(action, "redacted") == 0                                  ? "redact"
        : strcmp(action, "sent_anyway") == 0                               ? "warn"
        : strcmp(action, "not_a_secret") == 0                              ? "note"
                                                                           : NULL;
    if (!decision) return error_reply("unknown action");
    char detail[1200];
    snprintf(detail, sizeof detail, "%s%s%s",
             strcmp(action, "sent_anyway") == 0 ? "user sent anyway: "
             : strcmp(action, "not_a_secret") == 0 ? "user says this was not a secret: "
             : strcmp(action, "redacted") == 0  ? "redacted before sending: "
             : strcmp(action, "cancelled") == 0 ? "user held the message: "
                                                : "message held: ",
             cJSON_IsString(s) && s->valuestring ? s->valuestring : "", "");
    kai_audit("browser", site_of(req), decision, "prompt", detail);
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", 1);
    return o;
}

/* The extension reports which AI-chat sites are open and its per-site redaction
 * and override counts. Site only — the extension never sends a full URL or any
 * chat text. Feeds the "AI chats" section (kai agents); it is visibility only
 * and changes no policy. */
static cJSON *handle_status(const cJSON *req) {
    const cJSON *sites = cJSON_GetObjectItemCaseSensitive(req, "sites");
    if (cJSON_IsArray(sites)) {
        const cJSON *s;
        cJSON_ArrayForEach(s, sites) {
            const cJSON *site = cJSON_GetObjectItemCaseSensitive(s, "site");
            if (!cJSON_IsString(site) || !site->valuestring) continue;
            const cJSON *ot = cJSON_GetObjectItemCaseSensitive(s, "open_tabs");
            const cJSON *rd = cJSON_GetObjectItemCaseSensitive(s, "redactions");
            const cJSON *ov = cJSON_GetObjectItemCaseSensitive(s, "overrides");
            /* kai_chat_record ignores anything that isn't a known chat site. */
            kai_chat_record(site->valuestring,
                            cJSON_IsNumber(ot) ? (int)ot->valuedouble : 0,
                            cJSON_IsNumber(rd) ? (int)rd->valuedouble : 0,
                            cJSON_IsNumber(ov) ? (int)ov->valuedouble : 0);
        }
    }
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", 1);
    return o;
}

int kai_native_host(const char *origin) {
    (void)origin; /* Chrome already restricted callers via allowed_origins */
    (void)kai_home();
    (void)kai_policy_file();
    (void)kai_audit_path();
    for (;;) {
        char *msg = NULL;
        int rc = read_msg(&msg);
        if (rc == -1) break;
        if (rc == -2) { write_msg(error_reply("message too large")); break; }
        cJSON *req = cJSON_Parse(msg);
        free(msg);
        const cJSON *type = req ? cJSON_GetObjectItemCaseSensitive(req, "type") : NULL;
        const char *t = cJSON_IsString(type) ? type->valuestring : "";
        cJSON *reply;
        if (strcmp(t, "ping") == 0) {
            reply = cJSON_CreateObject();
            cJSON_AddBoolToObject(reply, "ok", 1);
            cJSON_AddStringToObject(reply, "version", KAI_VERSION);
        } else if (strcmp(t, "scan") == 0) {
            reply = handle_scan(req);
        } else if (strcmp(t, "decision") == 0) {
            reply = handle_decision(req);
        } else if (strcmp(t, "status") == 0) {
            reply = handle_status(req);
        } else {
            reply = error_reply("unknown request");
        }
        cJSON_Delete(req);
        write_msg(reply);
    }
    kai_policy_free(policy);
    return 0;
}
