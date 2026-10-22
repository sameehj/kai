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
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* Stable canonical form over every field except the HMAC itself. */
static int grant_canonical(const kai_grant *g, char *buf, size_t n) {
    int w = snprintf(buf, n, "%s\n%lld\n%lld\n%d\n%llu\n%s\n%d\n%s\n%d\n%d\n%s",
                     g->id, g->created_utc, g->expires_utc, g->pid, g->pidversion,
                     g->agent, g->strength, g->resource, g->op, g->scope,
                     g->approved_by);
    return w > 0 && (size_t)w < n;
}

static void hex32(const uint8_t d[32], char out[65]) {
    static const char hx[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[i*2] = hx[d[i]>>4]; out[i*2+1] = hx[d[i]&15]; }
    out[64] = '\0';
}

void kai_grant_sign(kai_grant *g, const unsigned char *key, size_t keylen) {
    char canon[2048];
    if (!grant_canonical(g, canon, sizeof canon)) { g->hmac[0] = '\0'; return; }
    uint8_t mac[32];
    hmac_sha256(key, keylen, canon, strlen(canon), mac);
    hex32(mac, g->hmac);
}

/* Constant-time-ish compare of the stored HMAC against a fresh one. */
int kai_grant_hmac_ok(const kai_grant *g, const unsigned char *key, size_t keylen) {
    if (!g || strlen(g->hmac) != 64) return 0;
    char canon[2048];
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
    cpy(out->hmac, sizeof out->hmac, o, "hmac");
    cJSON_Delete(o);
    return out->id[0] != '\0';
}

/* ---- load ---- */
static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
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
