/*
 * Kai — Scoped Approvals, M0 engine.
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Pure, offline-testable grant logic: a grant is signed (HMAC-SHA256) over its
 * canonical form with the approval key. Because the key lives in a control-path
 * -protected file an agent cannot read, an agent that writes a grant file into
 * ~/.kai/grants cannot produce a valid HMAC, so its self-written grant is never
 * honored (confused-deputy / self-approval defense). A grant can turn a
 * SOFT-protected path into allow, but kai_storage_decide refuses to let any
 * grant override an un-exemptable (builtin/control) path. Resource matching is
 * exact on the realpath-canonical path, so a symlink can't widen a grant.
 *
 * This file changes no live enforcement state; it is wired into the engine and
 * exercised by unit tests. The ES client and CLI consume it in later milestones.
 */
#include "internal.h"
#include "kai.h"
#include "cJSON.h"

#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

void kai_sha256(const void *data, size_t n, uint8_t out[32]); /* src/sha256.c */

/* ---- HMAC-SHA256 ---- */
static void hmac_sha256(const unsigned char *key, size_t keylen,
                        const char *msg, size_t msglen, uint8_t out[32]) {
    unsigned char k[64];
    memset(k, 0, sizeof k);
    if (keylen > 64) kai_sha256(key, keylen, k);      /* long key -> hash it */
    else if (keylen) memcpy(k, key, keylen);

    unsigned char ipad[64], opad[64];
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }

    unsigned char *inner = malloc(64 + msglen);
    if (!inner) { memset(out, 0, 32); return; }
    memcpy(inner, ipad, 64);
    memcpy(inner + 64, msg, msglen);
    uint8_t ih[32];
    kai_sha256(inner, 64 + msglen, ih);
    free(inner);

    unsigned char outer[64 + 32];
    memcpy(outer, opad, 64);
    memcpy(outer + 64, ih, 32);
    kai_sha256(outer, sizeof outer, out);
}

/* Stable canonical form over every field except the HMAC itself. Versioned: a
 * v1 grant keeps the exact v1 string (so old signatures still verify); a v2
 * grant prepends "v2" and appends session_id/project/dest_kind, so a v1 record
 * can never be replayed as v2 or vice-versa. */
static int grant_canonical(const kai_grant *g, char *buf, size_t n) {
    int w;
    if (g->grant_version >= 3) {
        /* v3 appends the honor flags so they are signed: an agent cannot flip
         * confirmed/authenticated on a signed grant to escalate its tier. */
        w = snprintf(buf, n, "v3\n%s\n%lld\n%lld\n%d\n%llu\n%s\n%d\n%s\n%d\n%d\n%s\n%s\n%s\n%d\n%d\n%d",
                     g->id, g->created_utc, g->expires_utc, g->pid, g->pidversion,
                     g->agent, g->strength, g->resource, g->op, g->scope, g->approved_by,
                     g->session_id, g->project, g->dest_kind, g->confirmed, g->authenticated);
    } else if (g->grant_version == 2) {
        w = snprintf(buf, n, "v2\n%s\n%lld\n%lld\n%d\n%llu\n%s\n%d\n%s\n%d\n%d\n%s\n%s\n%s\n%d",
                     g->id, g->created_utc, g->expires_utc, g->pid, g->pidversion,
                     g->agent, g->strength, g->resource, g->op, g->scope, g->approved_by,
                     g->session_id, g->project, g->dest_kind);
    } else {
        w = snprintf(buf, n, "%s\n%lld\n%lld\n%d\n%llu\n%s\n%d\n%s\n%d\n%d\n%s",
                     g->id, g->created_utc, g->expires_utc, g->pid, g->pidversion,
                     g->agent, g->strength, g->resource, g->op, g->scope, g->approved_by);
    }
    return w > 0 && (size_t)w < n;
}

static void hex32(const uint8_t d[32], char out[65]) {
    static const char hx[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[i*2] = hx[d[i]>>4]; out[i*2+1] = hx[d[i]&15]; }
    out[64] = '\0';
}

void kai_grant_sign(kai_grant *g, const unsigned char *key, size_t keylen) {
    char canon[4096];
    if (!grant_canonical(g, canon, sizeof canon)) { g->hmac[0] = '\0'; return; }
    uint8_t mac[32];
    hmac_sha256(key, keylen, canon, strlen(canon), mac);
    hex32(mac, g->hmac);
}

/* Constant-time-ish compare of the stored HMAC against a fresh one. */
int kai_grant_hmac_ok(const kai_grant *g, const unsigned char *key, size_t keylen) {
    if (!g || strlen(g->hmac) != 64) return 0;
    char canon[4096];
    if (!grant_canonical(g, canon, sizeof canon)) return 0;
    uint8_t mac[32];
    char hex[65];
    hmac_sha256(key, keylen, canon, strlen(canon), mac);
    hex32(mac, hex);
    unsigned diff = 0;
    for (int i = 0; i < 64; i++) diff |= (unsigned)(g->hmac[i] ^ hex[i]);
    return diff == 0;
}

/* ---- JSON ---- */
char *kai_grant_to_json(const kai_grant *g) {
    cJSON *o = cJSON_CreateObject();
    if (!o) return NULL;
    char pv[32], cr[32], ex[32];
    snprintf(pv, sizeof pv, "%llu", g->pidversion);
    snprintf(cr, sizeof cr, "%lld", g->created_utc);
    snprintf(ex, sizeof ex, "%lld", g->expires_utc);
    cJSON_AddStringToObject(o, "id", g->id);
    cJSON_AddStringToObject(o, "created_utc", cr);
    cJSON_AddStringToObject(o, "expires_utc", ex);
    cJSON_AddNumberToObject(o, "pid", g->pid);
    cJSON_AddStringToObject(o, "pidversion", pv);
    cJSON_AddStringToObject(o, "agent", g->agent);
    cJSON_AddNumberToObject(o, "strength", g->strength);
    cJSON_AddStringToObject(o, "resource", g->resource);
    cJSON_AddNumberToObject(o, "op", g->op);
    cJSON_AddNumberToObject(o, "scope", g->scope);
    cJSON_AddStringToObject(o, "approved_by", g->approved_by);
    cJSON_AddNumberToObject(o, "grant_version", g->grant_version);
    cJSON_AddStringToObject(o, "session_id", g->session_id);
    cJSON_AddStringToObject(o, "project", g->project);
    cJSON_AddNumberToObject(o, "dest_kind", g->dest_kind);
    cJSON_AddNumberToObject(o, "confirmed", g->confirmed);
    cJSON_AddNumberToObject(o, "authenticated", g->authenticated);
    cJSON_AddStringToObject(o, "hmac", g->hmac);
    char *s = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return s;
}

static void cpy(char *dst, size_t n, const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItem(o, k);
    if (v && cJSON_IsString(v) && v->valuestring) kai_strlcpy(dst, v->valuestring, n);
    else dst[0] = '\0';
}
static long long num_str(const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItem(o, k);
    if (v && cJSON_IsString(v) && v->valuestring) return strtoll(v->valuestring, NULL, 10);
    if (v && cJSON_IsNumber(v)) return (long long)v->valuedouble;
    return 0;
}
static int num_int(const cJSON *o, const char *k) {
    const cJSON *v = cJSON_GetObjectItem(o, k);
    return (v && cJSON_IsNumber(v)) ? v->valueint : 0;
}

int kai_grant_from_json(const char *json, kai_grant *out) {
    if (!json || !out) return 0;
    cJSON *o = cJSON_Parse(json);
    if (!o) return 0;
    memset(out, 0, sizeof *out);
    cpy(out->id, sizeof out->id, o, "id");
    out->created_utc = num_str(o, "created_utc");
    out->expires_utc = num_str(o, "expires_utc");
    out->pid = num_int(o, "pid");
    out->pidversion = (unsigned long long)num_str(o, "pidversion");
    cpy(out->agent, sizeof out->agent, o, "agent");
    out->strength = num_int(o, "strength");
    cpy(out->resource, sizeof out->resource, o, "resource");
    out->op = num_int(o, "op");
    out->scope = num_int(o, "scope");
    cpy(out->approved_by, sizeof out->approved_by, o, "approved_by");
    out->grant_version = num_int(o, "grant_version");
    cpy(out->session_id, sizeof out->session_id, o, "session_id");
    cpy(out->project, sizeof out->project, o, "project");
    out->dest_kind = num_int(o, "dest_kind");
    out->confirmed = num_int(o, "confirmed");
    out->authenticated = num_int(o, "authenticated");
    cpy(out->hmac, sizeof out->hmac, o, "hmac");
    cJSON_Delete(o);
    return out->id[0] != '\0';
}

/* Write a structured grant lifecycle audit record. Logs only identifiers (grant
 * id, resource path, agent name, action, outcome, short reason) -- never a key,
 * file contents, or credential. source="grant"; the hash chain covers it like
 * any other record. Auditing is a side effect: it never gates a decision. */
void kai_grant_audit(const char *action, const char *id, const char *agent,
                     const char *resource, int op, const char *outcome, const char *reason) {
    const char *ops = op == KAI_OP_WRITE ? "write" : op == KAI_OP_CONNECT ? "connect" : "read";
    char detail[512];
    snprintf(detail, sizeof detail, "grant %s id=%s agent=%s%s%s",
             action ? action : "?", id ? id : "?", agent ? agent : "?",
             (reason && *reason) ? " " : "", (reason && *reason) ? reason : "");
    kai_audit_entry e;
    memset(&e, 0, sizeof e);
    e.source = "grant";
    e.event = action ? action : "grant";
    e.decision = outcome ? outcome : "note";
    e.rule = ops;
    e.detail = detail;
    e.target = resource;
    kai_audit_write(&e);
}

/* Build + sign a grant from scalar/string fields and return its JSON (caller
 * frees). For the app's approve action: every field is the app's/human's, and
 * the identity fields come from the Kai-verified pending request, never from
 * agent-supplied text. Keeps Swift from having to fill C fixed-size arrays. */
char *kai_grant_build_json(const char *id, long long created, long long expires,
                           int pid, unsigned long long pidversion, const char *agent,
                           int strength, const char *resource, int op, int scope,
                           const char *approved_by, const unsigned char *key, size_t keylen) {
    kai_grant g;
    memset(&g, 0, sizeof g);
    kai_strlcpy(g.id, id ? id : "", sizeof g.id);
    g.created_utc = created;
    g.expires_utc = expires;
    g.pid = pid;
    g.pidversion = pidversion;
    kai_strlcpy(g.agent, agent ? agent : "", sizeof g.agent);
    g.strength = strength;
    kai_strlcpy(g.resource, resource ? resource : "", sizeof g.resource);
    g.op = op;
    g.scope = scope;
    kai_strlcpy(g.approved_by, approved_by ? approved_by : "", sizeof g.approved_by);
    g.grant_version = 1;
    kai_grant_sign(&g, key, keylen);
    return kai_grant_to_json(&g);
}

char *kai_grant_build_json2(const char *id, long long created, long long expires,
                            int pid, unsigned long long pidversion, const char *agent,
                            int strength, const char *resource, int op, int scope,
                            const char *approved_by, const char *session_id,
                            const char *project, int dest_kind,
                            const unsigned char *key, size_t keylen) {
    kai_grant g;
    memset(&g, 0, sizeof g);
    kai_strlcpy(g.id, id ? id : "", sizeof g.id);
    g.created_utc = created;
    g.expires_utc = expires;
    g.pid = pid;
    g.pidversion = pidversion;
    kai_strlcpy(g.agent, agent ? agent : "", sizeof g.agent);
    g.strength = strength;
    kai_strlcpy(g.resource, resource ? resource : "", sizeof g.resource);
    g.op = op;
    g.scope = scope;
    kai_strlcpy(g.approved_by, approved_by ? approved_by : "", sizeof g.approved_by);
    g.grant_version = 2;
    kai_strlcpy(g.session_id, session_id ? session_id : "", sizeof g.session_id);
    kai_strlcpy(g.project, project ? project : "", sizeof g.project);
    g.dest_kind = dest_kind;
    kai_grant_sign(&g, key, keylen);
    return kai_grant_to_json(&g);
}

char *kai_grant_build_json3(const char *id, long long created, long long expires,
                            int pid, unsigned long long pidversion, const char *agent,
                            int strength, const char *resource, int op, int scope,
                            const char *approved_by, const char *session_id,
                            const char *project, int dest_kind,
                            int confirmed, int authenticated,
                            const unsigned char *key, size_t keylen) {
    kai_grant g;
    memset(&g, 0, sizeof g);
    kai_strlcpy(g.id, id ? id : "", sizeof g.id);
    g.created_utc = created;
    g.expires_utc = expires;
    g.pid = pid;
    g.pidversion = pidversion;
    kai_strlcpy(g.agent, agent ? agent : "", sizeof g.agent);
    g.strength = strength;
    kai_strlcpy(g.resource, resource ? resource : "", sizeof g.resource);
    g.op = op;
    g.scope = scope;
    kai_strlcpy(g.approved_by, approved_by ? approved_by : "", sizeof g.approved_by);
    g.grant_version = 3;
    kai_strlcpy(g.session_id, session_id ? session_id : "", sizeof g.session_id);
    kai_strlcpy(g.project, project ? project : "", sizeof g.project);
    g.dest_kind = dest_kind;
    g.confirmed = confirmed ? 1 : 0;
    g.authenticated = authenticated ? 1 : 0;
    kai_grant_sign(&g, key, keylen);
    return kai_grant_to_json(&g);
}

/* ---- load ---- */
static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

/* A one-shot grant that has been spent leaves a durable "<dir>/<id>.used"
 * marker (written by the store on consume). A grant whose marker exists is
 * treated as already consumed and is NOT loaded, so a spent one-shot stays
 * spent across reload, extension restart, and replay of the signed file under a
 * new name (the marker is keyed by the grant id inside the JSON, not the
 * filename). This is what makes one-shot single-use durable rather than only
 * in-memory. */
int kai_grant_is_consumed(const char *dir, const char *id) {
    char fp[PATH_MAX];
    if (snprintf(fp, sizeof fp, "%s/%s.used", dir, id) >= (int)sizeof fp) return 0;
    struct stat st;
    return stat(fp, &st) == 0;
}

int kai_grants_load(const char *dir, kai_grant **out, int *n) {
    *out = NULL; *n = 0;
    DIR *d = opendir(dir);
    if (!d) return 0;                 /* no grants dir = no grants (not an error) */
    kai_grant *arr = NULL;
    int count = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || !ends_with(e->d_name, ".json")) continue;
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= (int)sizeof path) continue;
        size_t len = 0;
        char *txt = kai_read_file(path, 1 << 20, &len);
        if (!txt) continue;
        kai_grant g;
        int ok = kai_grant_from_json(txt, &g);
        free(txt);
        if (!ok) continue;
        if (kai_grant_is_consumed(dir, g.id)) continue; /* spent one-shot: stays spent */
        if (count == cap) {
            int ncap = cap ? cap * 2 : 8;
            kai_grant *na = realloc(arr, (size_t)ncap * sizeof *na);
            if (!na) break;
            arr = na; cap = ncap;
        }
        arr[count++] = g;
    }
    closedir(d);
    *out = arr; *n = count;
    return count;
}

/* ---- safe pause (M1.7) ----
 * A wall can be paused for a bounded window with auto-resume, distinct from a
 * full disable. The state is a file <home>/pause-<wall> holding an expiry epoch;
 * it lives under the control-path-protected home (an agent can't write it). The
 * extensions read it OFF their reload path (never in the hot handler) and resume
 * automatically once the expiry passes -- no timer needed. */
int kai_wall_paused(const char *wall, long long now) {
    if (!wall) return 0;
    char fp[PATH_MAX];
    /* Item 4: pause markers live in the protected registry so an agent-tree
     * process can't write one (the storage wall denies control-store writes). */
    if (snprintf(fp, sizeof fp, "%s/registry/pause-%s", kai_home(), wall) >= (int)sizeof fp) return 0;
    size_t n = 0;
    char *t = kai_read_file(fp, 64, &n);
    if (!t) return 0;
    long long until = strtoll(t, NULL, 10);
    free(t);
    return until > now;              /* expired/absent => not paused (auto-resume) */
}

/* Write (minutes>0) or clear (minutes<=0) a wall pause. Returns 0 on success. */
int kai_wall_pause_write(const char *wall, long long minutes) {
    if (!wall) return -1;
    char fp[PATH_MAX];
    mkdir(kai_home(), 0700);
    char rdir[PATH_MAX];
    if (snprintf(rdir, sizeof rdir, "%s/registry", kai_home()) < (int)sizeof rdir) mkdir(rdir, 0700);
    if (snprintf(fp, sizeof fp, "%s/registry/pause-%s", kai_home(), wall) >= (int)sizeof fp) return -1;
    if (minutes <= 0) { unlink(fp); return 0; }       /* resume now */
    long long until = (long long)time(NULL) + minutes * 60;
    int fd = open(fp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    dprintf(fd, "%lld\n", until);
    close(fd);
    return 0;
}

/* ---- match + decide ---- */
int kai_grant_match(const kai_grant *grants, int n, const kai_grant_subject *s,
                    const char *resolved_path, int op, long long now,
                    const unsigned char *key, size_t keylen) {
    if (!grants || !s || !resolved_path) return -1;
    for (int i = 0; i < n; i++) {
        const kai_grant *g = &grants[i];
        if (!kai_grant_hmac_ok(g, key, keylen)) continue;          /* forged/tampered */
        if (g->op != op) continue;
        if (g->expires_utc != 0 && now >= g->expires_utc) continue; /* expired */
        /* Identity binding (S4 session-wide fix): a SESSION-scoped grant (it
         * carries a session_id) matches ANY process in that verified session —
         * the whole tree, including children and brand-new processes — because
         * the session id is Kai-observed and unforgeable. A grant with no
         * session_id stays bound to the exact pid+pidversion that requested it. */
        if (g->session_id[0]) {
            if (!s->session_id || strcmp(g->session_id, s->session_id) != 0) continue;
        } else {
            if (g->pid != s->pid || g->pidversion != s->pidversion) continue;
        }
        if (s->agent && g->agent[0] && strcmp(g->agent, s->agent) != 0) continue;
        if (s->strength < g->strength) continue;            /* downgraded identity */
        if (g->strength <= KAI_ID_WEAK && g->scope != KAI_GRANT_ONESHOT) continue;
        if (g->grant_version >= 2 && g->project[0]) {        /* v2 project binding */
            if (!s->project || strcmp(g->project, s->project) != 0) continue;
        }
        if (strcmp(g->resource, resolved_path) != 0) continue; /* exact canonical */
        return i;
    }
    return -1;
}

/* ---- MCP session grants (Step 4) ----
 * An MCP tool approval becomes a session-bound grant like any other, with the
 * resource "mcp:<server>/<tool>" (or a server-wide wildcard tool). The hook honors it so a
 * once-approved server runs for the rest of that session; a different session
 * has no such grant and is asked again. The hook runs as the signed `kai`
 * (wall-exempt for reads), so it can read the grant store and the approval key
 * and verify the HMAC - an agent cannot forge one. */
/* key NULL: trust by LOCATION instead of signature - used by the hook, which
 * runs in the agent's tree and (rightly) can't read the approval key. The
 * grants folder is in the policy store, which only the installed Kai app may
 * write (the storage wall enforces it); with the wall off an agent could read
 * the key anyway, so the signature adds nothing then. */
int kai_mcp_grant_allows(const kai_grant *grants, int n, const char *session_id,
                         const char *server, const char *tool, long long now,
                         const unsigned char *key, size_t keylen) {
    if (!grants || !session_id || !*session_id || !server) return 0;
    char exact[KAI_GRANT_RES_MAX], wild[KAI_GRANT_RES_MAX];
    snprintf(exact, sizeof exact, "mcp:%s/%s", server, tool ? tool : "");
    snprintf(wild, sizeof wild, "mcp:%s/*", server);
    for (int i = 0; i < n; i++) {
        const kai_grant *g = &grants[i];
        if (key && !kai_grant_hmac_ok(g, key, keylen)) continue;   /* forged/tampered */
        if (g->expires_utc != 0 && now >= g->expires_utc) continue; /* expired */
        if (!g->session_id[0] || strcmp(g->session_id, session_id) != 0) continue; /* session only */
        if (strcmp(g->resource, exact) == 0 || strcmp(g->resource, wild) == 0) return 1;
    }
    return 0;
}

/* Read the approval key bytes from the control store. Only the signed app and
 * the walls (and the signed hook, which is read-exempt) can read it. */
size_t kai_approval_key_read(unsigned char *out, size_t cap) {
    if (!out || !cap) return 0;
    char fp[1200];
    if (snprintf(fp, sizeof fp, "%s/approval.key", kai_home()) >= (int)sizeof fp) return 0;
    FILE *f = fopen(fp, "rb");
    if (!f) return 0;
    size_t nread = fread(out, 1, cap, f);
    fclose(f);
    return nread;
}

void kai_sha256_hex(const void *data, size_t n, char out[65]);  /* sha256.c */

/* Write a pending MCP approval request for the app to show as a card. Keyed by
 * session+server+tool so re-asking overwrites rather than piling up. */
static void mcp_request_write(const char *session, const char *server, const char *tool,
                              const char *host, const char *agent) {
    char dir[1200];
    if (snprintf(dir, sizeof dir, "%s/pending", kai_home()) >= (int)sizeof dir) return;
    mkdir(kai_home(), 0700);
    mkdir(dir, 0700);
    char keybuf[400], h[65];
    snprintf(keybuf, sizeof keybuf, "%s|mcp:%s/%s", session, server, tool ? tool : "");
    kai_sha256_hex(keybuf, strlen(keybuf), h);
    char resource[256];
    snprintf(resource, sizeof resource, "mcp:%.90s/%.90s", server, tool ? tool : "");
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "id", h);
    cJSON_AddStringToObject(o, "agent", agent && *agent ? agent : "agent");
    cJSON_AddNumberToObject(o, "pid", 0);
    cJSON_AddNumberToObject(o, "pidversion", 0);
    cJSON_AddNumberToObject(o, "strength", 2);
    cJSON_AddStringToObject(o, "resource", resource);
    cJSON_AddStringToObject(o, "op", "connect");
    cJSON_AddNumberToObject(o, "ts", (double)time(NULL));
    cJSON_AddStringToObject(o, "session", session);   /* from the caller's token, not the payload */
    cJSON_AddStringToObject(o, "note", "MCP tool - approve for this session");
    if (host && *host) cJSON_AddStringToObject(o, "declaredHost", host);
    char *js = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!js) return;
    char path[1300], tmp[1400];
    snprintf(path, sizeof path, "%s/mcp-%.16s.json", dir, h);
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (f) { chmod(tmp, 0600); fputs(js, f);
             if (fclose(f) == 0) { if (rename(tmp, path) != 0) unlink(tmp); } else unlink(tmp); }
    free(js);
}

/* Service side of an MCP call (Step 4 / Change 2). Runs in the signed app, the
 * only process that may read the approval key. Derives the session from the
 * CALLER's pid (audit-token identity), never a payload-supplied id. If a valid
 * session grant already covers the tool -> allow (rc 0). Otherwise stage a
 * pending card for the user and tell the agent to wait (rc 10). */
/* An MCP call, decided where the hook runs (v1: no control service). The
 * session comes from the caller's pid via the wall's map - never a parameter
 * a caller could spoof. A session grant allows it (0); otherwise a Kai card is
 * staged (10); no Kai session: denied (72). verify_signature 0 = the hook. */
int kai_mcp_request(int caller_pid, const char *server, const char *tool,
                    const char *host, int verify_signature, char *msg, size_t msglen) {
    if (msg && msglen) msg[0] = '\0';
    if (!server || !*server) { if (msg) kai_strlcpy(msg, "bad MCP request", msglen); return 1; }
    char session[KAI_SESSION_ID_MAX] = "";
    /* Ancestry walk from the caller (the hook) up to the agent root; the live
     * pidversion of each hop isn't available here, so pass 0 (trust the files -
     * the ES wall's in-memory cache is the pid-reuse guard for grant decisions). */
    if (!kai_session_for_pid(caller_pid, 0, session, sizeof session)) {
        if (msg) kai_strlcpy(msg, "no Kai session for the caller; MCP denied", msglen);
        return 72;
    }
    char gdir[1200]; snprintf(gdir, sizeof gdir, "%s/grants", kai_home());
    kai_grant *gs = NULL; int ng = 0;
    kai_grants_load(gdir, &gs, &ng);
    unsigned char key[64]; size_t klen = verify_signature ? kai_approval_key_read(key, sizeof key) : 0;
    int allowed = gs && (!verify_signature || klen) &&
                  kai_mcp_grant_allows(gs, ng, session, server, tool, (long long)time(NULL),
                                       verify_signature ? key : NULL, klen);
    free(gs);
    if (allowed) { if (msg) kai_strlcpy(msg, "granted for this session", msglen); return 0; }

    kai_session sess; char agent[32] = "agent";
    if (kai_session_get(session, &sess) == 0 && sess.agent[0]) kai_strlcpy(agent, sess.agent, sizeof agent);
    mcp_request_write(session, server, tool, host, agent);
    if (msg) snprintf(msg, msglen, "waiting for approval in Kai: %s/%s", server, tool ? tool : "");
    return 10;
}

static int host_from_url(const char *url, char *out, size_t n) {
    const char *p = strstr(url, "://");
    p = p ? p + 3 : url;
    size_t i = 0;
    while (p[i] && p[i] != '/' && p[i] != ':' && i + 1 < n) { out[i] = p[i]; i++; }
    out[i] = '\0';
    return i > 0;
}

/* The host an MCP server declares in .mcp.json (project cwd). A PROPOSAL only
 * (M2.5): it lets the approval card offer "also allow <host> for this session",
 * but never allows anything on its own. Returns 1 and fills out if found. */
int kai_mcp_declared_host(const char *server, const char *cwd, char *out, size_t n) {
    if (out && n) out[0] = '\0';
    if (!server || !out || !n) return 0;
    char path[1300];
    snprintf(path, sizeof path, "%s/.mcp.json", (cwd && *cwd) ? cwd : ".");
    size_t len = 0; char *txt = kai_read_file(path, 1 << 20, &len);
    if (!txt) return 0;
    cJSON *o = cJSON_Parse(txt); free(txt);
    if (!o) return 0;
    cJSON *servers = cJSON_GetObjectItem(o, "mcpServers");
    cJSON *s = servers ? cJSON_GetObjectItem(servers, server) : NULL;
    const char *url = s ? cJSON_GetStringValue(cJSON_GetObjectItem(s, "url")) : NULL;
    int found = (url && *url) ? host_from_url(url, out, n) : 0;
    cJSON_Delete(o);
    return found;
}

/* S4: does this signed grant meet the override tier of the resource it covers?
 * never: never; break-glass: a read or write (the op it was signed for, which
 * kai_grant_match already checks), authenticated, capped at 15 min;
 * override: only if the user confirmed; confirm/normal: yes. The flags are part
 * of the signed canonical form, so an agent cannot forge them. */
int kai_grant_satisfies_tier(const kai_grant *g, kai_override_tier_t tier) {
    if (!g) return 0;
    switch (tier) {
    case KAI_TIER_NEVER: return 0;
    case KAI_TIER_BREAKGLASS:
        return g->authenticated &&
               (g->op == KAI_OP_READ || g->op == KAI_OP_WRITE) &&
               g->expires_utc != 0 && (g->expires_utc - g->created_utc) <= 900;
    case KAI_TIER_OVERRIDE: return g->confirmed != 0;
    default: return 1;   /* KAI_TIER_CONFIRM and anything else */
    }
}

/* S4: a session-bound grant stops being honored once its session has ended
 * (root exit, recorded in the registry). An unknown session is treated as
 * still active, so a grant made before the registry existed is unaffected. */
int kai_grant_session_ended(const kai_grant *g) {
    if (!g || !g->session_id[0]) return 0;
    kai_session s;
    return kai_session_get(g->session_id, &s) && s.ended_utc != 0;
}

int kai_storage_decide(const kai_policy *p, const char *resolved_path,
                       const char *cwd, int op, const kai_grant_subject *s,
                       const kai_grant *grants, int ngrants, long long now,
                       const unsigned char *key, size_t keylen,
                       char *why, size_t whylen) {
    if (!kai_path_protected(p, resolved_path, cwd, why, whylen)) return 1; /* allow */
    if (kai_rule_is_builtin(why)) return 0;      /* un-exemptable: no grant overrides */
    kai_override_tier_t tier = kai_override_tier(why);   /* before `why` is overwritten */
    if (s) {
        int idx = kai_grant_match(grants, ngrants, s, resolved_path, op, now, key, keylen);
        if (idx >= 0) {
            const kai_grant *g = &grants[idx];
            if (!kai_grant_satisfies_tier(g, tier)) return 0;  /* grant too weak for the tier */
            if (kai_grant_session_ended(g)) return 0;          /* session is over */
            if (why) kai_strlcpy(why, "scoped grant", whylen);
            return 1;                            /* soft-protected, grant allows */
        }
    }
    return 0;                                    /* soft-protected, no grant: deny */
}

int kai_grant_resolve(const char *path, char *buf, size_t buflen) {
    if (!path || !buf || !buflen) return 0;
    char tmp[PATH_MAX];
    if (realpath(path, tmp)) {                   /* resolves symlinks */
        if (strlen(tmp) + 1 > buflen) return 0;
        memcpy(buf, tmp, strlen(tmp) + 1);
        return 1;
    }
    char *nz = kai_normalize_path(path, NULL);   /* fallback: lexical */
    if (!nz) return 0;
    kai_strlcpy(buf, nz, buflen);
    free(nz);
    return 1;
}

/* ---- B2: persistent decisions (Keep blocked, Allow rules) ----
 * One signed file per decision under <kai home>/rules. Each binds to the
 * VERIFIED agent identity (signing id + team, never a process name or an
 * agent-supplied id) and an exact destination. Keep blocked only stops a card
 * from being shown again; an Allow rule lets the destination through for every
 * future session of that agent, so it needs owner authentication when made
 * (signed into the rule) and a real hostname (never an IP from an unknown host).
 * Both are signed: an agent can't write ~/.kai, and a file copied from
 * elsewhere won't verify under this Mac's approval key. */
static int rule_canonical(const kai_decision_rule *r, char *buf, size_t n) {
    /* rule1 for rules that last until removed (their signatures stay valid);
     * rule2 signs the expiry too; rule3 also signs "migrated". */
    int w = r->migrated
        ? snprintf(buf, n, "rule3\n%s\n%d\n%s\n%s\n%s\n%d\n%lld\n%lld\n%d\n%d",
                   r->id, r->kind, r->identity, r->agent, r->dest, r->op,
                   r->created_utc, r->expires_utc, r->authenticated, r->migrated)
        : r->expires_utc
        ? snprintf(buf, n, "rule2\n%s\n%d\n%s\n%s\n%s\n%d\n%lld\n%lld\n%d",
                   r->id, r->kind, r->identity, r->agent, r->dest, r->op,
                   r->created_utc, r->expires_utc, r->authenticated)
        : snprintf(buf, n, "rule1\n%s\n%d\n%s\n%s\n%s\n%d\n%lld\n%d",
                   r->id, r->kind, r->identity, r->agent, r->dest, r->op,
                   r->created_utc, r->authenticated);
    return w > 0 && (size_t)w < n;
}

/* An Allow either carries owner authentication or is temporary (a day at most). */
static int allow_ok(const kai_decision_rule *r) {
    if (r->migrated)   /* carried over from a switch: at most 7 days, never authenticated */
        return !r->authenticated && r->expires_utc > r->created_utc && r->expires_utc - r->created_utc <= 7 * 86400;
    if (r->authenticated) return 1;
    return r->expires_utc > r->created_utc && r->expires_utc - r->created_utc <= 86400;
}

static int rule_hmac_ok(const kai_decision_rule *r, const unsigned char *key, size_t keylen) {
    if (!key || !keylen || strlen(r->hmac) != 64) return 0;
    char canon[3072], hex[65];
    uint8_t mac[32];
    if (!rule_canonical(r, canon, sizeof canon)) return 0;
    hmac_sha256(key, keylen, canon, strlen(canon), mac);
    hex32(mac, hex);
    unsigned diff = 0;
    for (int i = 0; i < 64; i++) diff |= (unsigned)(r->hmac[i] ^ hex[i]);
    return diff == 0;
}

static int is_ip_literal(const char *d) {
    if (d[0] == '[') return 1;                       /* [v6]:port */
    for (const char *p = d; *p && *p != ':'; p++)
        if (!(isdigit((unsigned char)*p) || *p == '.')) return 0;
    return 1;
}

int kai_rule_dest_ok(int kind, const char *dest) {
    if (!dest || !*dest || strlen(dest) >= KAI_GRANT_RES_MAX) return 0;
    /* A connection with no known hostname gets "this connection" only: no Allow
     * rule from an address that may front many sites. */
    if (kind == KAI_RULE_ALLOW && dest[0] != '/' && is_ip_literal(dest)) return 0;
    return 1;
}

char *kai_rule_build_json(const char *id, int kind, const char *identity, const char *agent,
                          const char *dest, int op, long long created, int authenticated,
                          const unsigned char *key, size_t keylen) {
    return kai_rule_build_json_until(id, kind, identity, agent, dest, op, created, 0, authenticated,
                                     key, keylen);
}

static char *rule_build(const char *id, int kind, const char *identity, const char *agent,
                        const char *dest, int op, long long created, long long expires,
                        int authenticated, int migrated, const unsigned char *key, size_t keylen);

char *kai_rule_build_json_migrated(const char *id, const char *identity, const char *agent, const char *dest,
                                   int op, long long created, long long expires,
                                   const unsigned char *key, size_t keylen) {
    return rule_build(id, KAI_RULE_ALLOW, identity, agent, dest, op, created, expires, 0, 1, key, keylen);
}

char *kai_rule_build_json_until(const char *id, int kind, const char *identity, const char *agent,
                                const char *dest, int op, long long created, long long expires,
                                int authenticated, const unsigned char *key, size_t keylen) {
    return rule_build(id, kind, identity, agent, dest, op, created, expires, authenticated, 0, key, keylen);
}

static char *rule_build(const char *id, int kind, const char *identity, const char *agent,
                        const char *dest, int op, long long created, long long expires,
                        int authenticated, int migrated, const unsigned char *key, size_t keylen) {
    if (!id || !*id || !identity || !*identity || !key || !keylen) return NULL;
    if (kind != KAI_RULE_ALLOW && kind != KAI_RULE_KEEP_BLOCKED) return NULL;
    if (!kai_rule_dest_ok(kind, dest)) return NULL;
    kai_decision_rule r;
    memset(&r, 0, sizeof r);
    kai_strlcpy(r.id, id, sizeof r.id);
    r.kind = kind;
    kai_strlcpy(r.identity, identity, sizeof r.identity);
    kai_strlcpy(r.agent, agent ? agent : "", sizeof r.agent);
    kai_strlcpy(r.dest, dest, sizeof r.dest);
    r.op = op;
    r.created_utc = created;
    r.expires_utc = expires;
    r.authenticated = authenticated ? 1 : 0;
    r.migrated = migrated ? 1 : 0;
    if (kind == KAI_RULE_ALLOW && !allow_ok(&r)) return NULL;
    char canon[3072];
    uint8_t mac[32];
    if (!rule_canonical(&r, canon, sizeof canon)) return NULL;
    hmac_sha256(key, keylen, canon, strlen(canon), mac);
    hex32(mac, r.hmac);
    cJSON *o = cJSON_CreateObject();
    if (!o) return NULL;
    char cr[32];
    snprintf(cr, sizeof cr, "%lld", r.created_utc);
    cJSON_AddStringToObject(o, "id", r.id);
    cJSON_AddStringToObject(o, "kind", kind == KAI_RULE_ALLOW ? "allow" : "keep_blocked");
    cJSON_AddStringToObject(o, "identity", r.identity);
    cJSON_AddStringToObject(o, "agent", r.agent);
    cJSON_AddStringToObject(o, "dest", r.dest);
    cJSON_AddNumberToObject(o, "op", r.op);
    cJSON_AddStringToObject(o, "created_utc", cr);
    if (r.expires_utc) {
        char ex[32];
        snprintf(ex, sizeof ex, "%lld", r.expires_utc);
        cJSON_AddStringToObject(o, "expires_utc", ex);
    }
    if (r.migrated) cJSON_AddNumberToObject(o, "migrated", 1);
    cJSON_AddNumberToObject(o, "authenticated", r.authenticated);
    cJSON_AddStringToObject(o, "hmac", r.hmac);
    char *out = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    return out;
}

int kai_rule_from_json(const char *json, kai_decision_rule *out) {
    if (!json || !out) return 0;
    cJSON *o = cJSON_Parse(json);
    if (!o) return 0;
    memset(out, 0, sizeof *out);
    char kind[24];
    cpy(out->id, sizeof out->id, o, "id");
    cpy(kind, sizeof kind, o, "kind");
    out->kind = !strcmp(kind, "allow") ? KAI_RULE_ALLOW
              : !strcmp(kind, "keep_blocked") ? KAI_RULE_KEEP_BLOCKED : 0;
    cpy(out->identity, sizeof out->identity, o, "identity");
    cpy(out->agent, sizeof out->agent, o, "agent");
    cpy(out->dest, sizeof out->dest, o, "dest");
    out->op = num_int(o, "op");
    out->created_utc = num_str(o, "created_utc");
    out->expires_utc = num_str(o, "expires_utc");
    out->migrated = num_int(o, "migrated");
    out->authenticated = num_int(o, "authenticated");
    cpy(out->hmac, sizeof out->hmac, o, "hmac");
    cJSON_Delete(o);
    return out->id[0] && out->kind;
}

int kai_migration_evidence(const char *agent, const char *host) {
    if (!agent || !host || !*host) return 0;
    char paths[2][1200];
    snprintf(paths[0], sizeof paths[0], "%s", kai_audit_path());
    snprintf(paths[1], sizeof paths[1], "%s.1", kai_audit_path());
    char agentkey[96];
    snprintf(agentkey, sizeof agentkey, "agent=%s ", agent);
    int found = 0;
    for (int f = 0; f < 2 && !found; f++) {
        size_t n = 0;
        char *t = kai_read_file(paths[f], 64u << 20, &n);
        if (!t) continue;
        for (char *line = strtok(t, "\n"); line && !found; line = strtok(NULL, "\n")) {
            if (!strstr(line, host)) continue;          /* cheap filter */
            cJSON *o = cJSON_Parse(line);
            if (!o) continue;
            const char *src = cJSON_GetStringValue(cJSON_GetObjectItem(o, "source"));
            const char *ev = cJSON_GetStringValue(cJSON_GetObjectItem(o, "event"));
            const char *tg = cJSON_GetStringValue(cJSON_GetObjectItem(o, "target"));
            const char *det = cJSON_GetStringValue(cJSON_GetObjectItem(o, "detail"));
            if (src && ev && tg && !strcasecmp(tg, host)) {
                if (!strcmp(src, "network") && !strcmp(ev, agent)) found = 1;
                else if (!strcmp(src, "grant") && (!strcmp(ev, "requested") || !strcmp(ev, "used")) &&
                         det && strstr(det, agentkey)) found = 1;
            }
            cJSON_Delete(o);
        }
        free(t);
    }
    return found;
}

const char *kai_rules_dir(void) {
    static char buf[1100];
    snprintf(buf, sizeof buf, "%s/rules", kai_home());
    return buf;
}

int kai_rule_lookup(const char *dir, const char *identity, const char *dest, int op,
                    const unsigned char *key, size_t keylen, char *id_out, size_t idn) {
    if (id_out && idn) id_out[0] = '\0';
    if (!identity || !*identity || !dest || !*dest) return 0;   /* unverified: no rules */
    DIR *d = opendir(dir ? dir : kai_rules_dir());
    if (!d) return 0;
    int found = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t nl = strlen(e->d_name);
        if (nl < 6 || strcmp(e->d_name + nl - 5, ".json") != 0) continue;
        char fp[PATH_MAX];
        if (snprintf(fp, sizeof fp, "%s/%s", dir ? dir : kai_rules_dir(), e->d_name) >= (int)sizeof fp) continue;
        size_t n = 0;
        char *js = kai_read_file(fp, 16384, &n);
        kai_decision_rule r;
        int ok = js && kai_rule_from_json(js, &r);
        free(js);
        if (!ok || !rule_hmac_ok(&r, key, keylen)) continue;           /* forged/tampered */
        if (r.op != op || strcmp(r.identity, identity) != 0 || strcasecmp(r.dest, dest) != 0) continue;
        if (r.expires_utc && (long long)time(NULL) >= r.expires_utc) continue;     /* ended */
        if (r.kind == KAI_RULE_ALLOW && (!allow_ok(&r) || !kai_rule_dest_ok(r.kind, r.dest))) continue;
        /* Keep blocked wins over an Allow for the same thing: the tighter one. */
        if (r.kind == KAI_RULE_KEEP_BLOCKED || !found) {
            if (id_out && idn) kai_strlcpy(id_out, r.id, idn);
            found = r.kind;
        }
        if (found == KAI_RULE_KEEP_BLOCKED) break;
    }
    closedir(d);
    return found;
}
