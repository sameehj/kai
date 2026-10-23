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

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    if (g->grant_version >= 2) {
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
    if (snprintf(fp, sizeof fp, "%s/pause-%s", kai_home(), wall) >= (int)sizeof fp) return 0;
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
    if (snprintf(fp, sizeof fp, "%s/pause-%s", kai_home(), wall) >= (int)sizeof fp) return -1;
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
        if (g->pid != s->pid || g->pidversion != s->pidversion) continue; /* identity */
        if (s->agent && g->agent[0] && strcmp(g->agent, s->agent) != 0) continue;
        if (s->strength < g->strength) continue;            /* downgraded identity */
        if (g->strength <= KAI_ID_WEAK && g->scope != KAI_GRANT_ONESHOT) continue;
        if (g->grant_version >= 2) {                         /* v2 session/project binding */
            if (g->session_id[0] && (!s->session_id || strcmp(g->session_id, s->session_id) != 0)) continue;
            if (g->project[0] && (!s->project || strcmp(g->project, s->project) != 0)) continue;
        }
        if (strcmp(g->resource, resolved_path) != 0) continue; /* exact canonical */
        return i;
    }
    return -1;
}

int kai_storage_decide(const kai_policy *p, const char *resolved_path,
                       const char *cwd, int op, const kai_grant_subject *s,
                       const kai_grant *grants, int ngrants, long long now,
                       const unsigned char *key, size_t keylen,
                       char *why, size_t whylen) {
    if (!kai_path_protected(p, resolved_path, cwd, why, whylen)) return 1; /* allow */
    if (kai_rule_is_builtin(why)) return 0;      /* un-exemptable: no grant overrides */
    if (s && kai_grant_match(grants, ngrants, s, resolved_path, op, now, key, keylen) >= 0) {
        if (why) kai_strlcpy(why, "scoped grant", whylen);
        return 1;                                /* soft-protected, grant allows */
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
