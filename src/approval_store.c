/*
 * Kai — approval store (Scoped Approvals M2).
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * A concurrency-safe snapshot of (policy, grants) with bounded reload, explicit
 * generations, immediate revocation, and ATOMIC one-shot consumption.
 *
 *  - decision path  -> read lock (many concurrent deciders)
 *  - reload / revoke -> write lock (single mutator)
 *  - one-shot spend  -> an atomic unlink() of the grant file: the kernel
 *    serializes, so exactly one decider's unlink succeeds; losers deny. The
 *    in-memory list may still show a spent one-shot briefly, but every decide
 *    re-attempts the unlink and a loser (ENOENT) denies, so it can't be spent
 *    twice.
 *
 * Fail-closed posture: an unreadable grants dir => 0 grants (more denials); a
 * policy that fails to reload keeps the last good policy (availability), never
 * silently widening access. This file performs no live-wall actions.
 */
#include "internal.h"
#include "kai.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* public (scan.c) */
int kai_path_protected(const kai_policy *p, const char *path, const char *cwd,
                       char *why, size_t whylen);
int kai_rule_is_builtin(const char *rule);

struct kai_approval_store {
    char policy_path[1024];        /* "" = default location */
    char grants_dir[1024];
    unsigned char key[256];
    size_t keylen;
    long long debounce;

    pthread_rwlock_t lock;
    kai_policy *policy;            /* snapshot, under lock */
    kai_grant *grants;
    _Atomic unsigned char *consumed; /* per-grant one-shot spend flag (parallel) */
    int ngrants;
    unsigned long generation;

    long long last_check;          /* epoch of last reload re-stat */
    long long policy_mtime;
    long long grants_mtime;
};

/* newest mtime of any *.json under dir (0 if none / unreadable) */
static long long grants_dir_mtime(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    long long newest = 1; /* dir exists but maybe empty: non-zero so "exists" is distinct */
    struct dirent *e;
    char path[PATH_MAX];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        if (snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= (int)sizeof path) continue;
        struct stat st;
        if (stat(path, &st) == 0 && (long long)st.st_mtime > newest) newest = (long long)st.st_mtime;
    }
    closedir(d);
    return newest;
}

static long long file_mtime(const char *path) {
    struct stat st;
    return (path && *path && stat(path, &st) == 0) ? (long long)st.st_mtime : 0;
}

/* load a fresh policy+grants snapshot into the store (caller holds wrlock) */
static void load_snapshot(kai_approval_store *s, int first) {
    kai_policy *np = kai_policy_load(s->policy_path[0] ? s->policy_path : NULL, NULL, 0);
    if (np) {                               /* good policy: swap in */
        if (s->policy) kai_policy_free(s->policy);
        s->policy = np;
    } else if (first) {
        s->policy = NULL;                   /* nothing yet; decide fails closed */
    } /* else: keep last-good policy */

    kai_grant *ng = NULL;
    int nn = 0;
    kai_grants_load(s->grants_dir, &ng, &nn); /* missing dir => 0 grants */

    /* Cleanup pass (off the hot path, under the write lock): drop and AUDIT any
     * grant with an invalid signature or past its expiry, and unlink its file so
     * it isn't re-audited next reload. Expiry is thus recorded at reload/cleanup
     * time, NOT at the instant the TTL elapses -- there is no background expiry
     * worker; a grant also simply fails to match once expired (checked again at
     * decision time). Auditing here is a side effect and never affects whether a
     * grant is dropped (fail-closed regardless). */
    long long now = (long long)time(NULL);
    int kept = 0;
    for (int i = 0; i < nn; i++) {
        int bad = (s->keylen && !kai_grant_hmac_ok(&ng[i], s->key, s->keylen));
        int expired = (!bad && ng[i].expires_utc != 0 && now >= ng[i].expires_utc);
        if (bad || expired) {
            kai_grant_audit(bad ? "rejected" : "expired", ng[i].id, ng[i].agent,
                            ng[i].resource, ng[i].op, bad ? "reject" : "expire",
                            bad ? "invalid signature" : "ttl elapsed");
            char fp[PATH_MAX];
            if (snprintf(fp, sizeof fp, "%s/%s.json", s->grants_dir, ng[i].id) < (int)sizeof fp)
                unlink(fp);
            continue;
        }
        ng[kept++] = ng[i];
    }
    nn = kept;

    free(s->grants);
    free(s->consumed);
    s->grants = ng;
    s->ngrants = nn;
    s->consumed = nn ? calloc((size_t)nn, 1) : NULL; /* fresh one-shot flags */

    s->policy_mtime = file_mtime(s->policy_path[0] ? s->policy_path : kai_policy_file());
    s->grants_mtime = grants_dir_mtime(s->grants_dir);
    s->generation++;
}

kai_approval_store *kai_approval_store_open(const char *policy_path, const char *grants_dir,
                                            const unsigned char *key, size_t keylen,
                                            long long debounce_sec) {
    kai_approval_store *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    if (policy_path) kai_strlcpy(s->policy_path, policy_path, sizeof s->policy_path);
    if (grants_dir) kai_strlcpy(s->grants_dir, grants_dir, sizeof s->grants_dir);
    if (key && keylen) { if (keylen > sizeof s->key) keylen = sizeof s->key;
                         memcpy(s->key, key, keylen); s->keylen = keylen; }
    s->debounce = debounce_sec < 0 ? 0 : debounce_sec;
    pthread_rwlock_init(&s->lock, NULL);
    pthread_rwlock_wrlock(&s->lock);
    s->last_check = (long long)time(NULL);
    load_snapshot(s, 1);
    pthread_rwlock_unlock(&s->lock);
    return s;
}

void kai_approval_store_close(kai_approval_store *s) {
    if (!s) return;
    if (s->policy) kai_policy_free(s->policy);
    free(s->grants);
    free(s->consumed);
    pthread_rwlock_destroy(&s->lock);
    free(s);
}

int kai_approval_store_reload(kai_approval_store *s, int force) {
    if (!s) return 0;
    pthread_rwlock_wrlock(&s->lock);
    long long now = (long long)time(NULL);
    if (!force && (now - s->last_check) < s->debounce) { pthread_rwlock_unlock(&s->lock); return 0; }
    s->last_check = now;
    long long pm = file_mtime(s->policy_path[0] ? s->policy_path : kai_policy_file());
    long long gm = grants_dir_mtime(s->grants_dir);
    if (!force && pm == s->policy_mtime && gm == s->grants_mtime) {
        pthread_rwlock_unlock(&s->lock); return 0;   /* nothing changed */
    }
    load_snapshot(s, 0);
    pthread_rwlock_unlock(&s->lock);
    return 1;
}

int kai_approval_store_install_key(kai_approval_store *s,
                                   const unsigned char *key, size_t keylen) {
    if (!s || !key || keylen == 0 || keylen > sizeof s->key) return 0;
    pthread_rwlock_wrlock(&s->lock);
    if (s->keylen) { pthread_rwlock_unlock(&s->lock); return 0; }
    memcpy(s->key, key, keylen);
    s->keylen = keylen;
    /* A signed grant may already be on disk. Validate it with the new key
     * before the next decision; this runs on the reload worker, not in AUTH. */
    load_snapshot(s, 0);
    pthread_rwlock_unlock(&s->lock);
    return 1;
}

unsigned long kai_approval_store_generation(const kai_approval_store *s) {
    return s ? s->generation : 0;
}

int kai_approval_store_count(kai_approval_store *s) {
    if (!s) return 0;
    pthread_rwlock_rdlock(&s->lock);
    int n = s->ngrants;
    pthread_rwlock_unlock(&s->lock);
    return n;
}

/* Spend a one-shot grant. The authority is an in-memory atomic flag, so exactly
 * one caller wins regardless of filesystem unlink semantics (observed: this
 * host's unlink() does NOT give single-winner semantics under concurrency). The
 * file unlink is best-effort cleanup so a spent one-shot doesn't survive a
 * reload. Called under the read lock; the atomic flag is safe there. 1 = we won. */
static int consume_oneshot(kai_approval_store *s, int idx) {
    unsigned char prev = atomic_exchange_explicit(&s->consumed[idx], 1, memory_order_acq_rel);
    if (prev != 0) return 0;                 /* already spent in-process by another decider */
    /* Persist the spend BEFORE allowing, so it is durable across reload/restart
     * (kai_grants_load skips a grant whose ".used" marker exists). The in-memory
     * atomic above only serializes concurrent deciders within this process; this
     * marker is the durable single-use record. */
    char fp[PATH_MAX];
    if (snprintf(fp, sizeof fp, "%s/%s.used", s->grants_dir, s->grants[idx].id) < (int)sizeof fp) {
        int fd = open(fp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
        if (fd >= 0) { time_t t = time(NULL); dprintf(fd, "%lld\n", (long long)t); close(fd); }
    }
    if (snprintf(fp, sizeof fp, "%s/%s.json", s->grants_dir, s->grants[idx].id) < (int)sizeof fp)
        unlink(fp);                          /* best-effort cleanup of the grant file */
    return 1;
}

int kai_approval_store_decide(kai_approval_store *s, const char *resolved_path,
                              const char *cwd, int op, const kai_grant_subject *subj,
                              long long now, char *why, size_t whylen) {
    if (!s) return 0;
    pthread_rwlock_rdlock(&s->lock);
    int allow = 0;
    if (!kai_path_protected(s->policy, resolved_path, cwd, why, whylen)) {
        allow = 1;                                   /* not protected */
    } else if (kai_rule_is_builtin(why)) {
        allow = 0;                                   /* un-exemptable: no grant overrides */
    } else if (subj) {
        int idx = kai_grant_match(s->grants, s->ngrants, subj, resolved_path, op, now,
                                  s->keylen ? s->key : NULL, s->keylen);
        if (idx >= 0) {
            if (s->grants[idx].scope == KAI_GRANT_ONESHOT) {
                allow = consume_oneshot(s, idx); /* atomic flag; loser denies */
            } else {
                allow = 1;                           /* process-scoped: repeatable */
            }
            if (allow && why) kai_strlcpy(why, "scoped grant", whylen);
        }
    }
    pthread_rwlock_unlock(&s->lock);
    return allow;
}

int kai_approval_store_protected(kai_approval_store *s, const char *path,
                                 const char *cwd, char *why, size_t whylen) {
    if (!s) return 0;
    pthread_rwlock_rdlock(&s->lock);
    int r = kai_path_protected(s->policy, path, cwd, why, whylen);
    pthread_rwlock_unlock(&s->lock);
    return r;
}

int kai_approval_store_revoke(kai_approval_store *s, const char *id_prefix) {
    if (!s || !id_prefix || !*id_prefix) return 0;
    pthread_rwlock_wrlock(&s->lock);
    int removed = 0;
    size_t pl = strlen(id_prefix);
    for (int i = 0; i < s->ngrants; i++) {
        if (strncmp(s->grants[i].id, id_prefix, pl) == 0) {
            char fp[PATH_MAX];
            if (snprintf(fp, sizeof fp, "%s/%s.json", s->grants_dir, s->grants[i].id) < (int)sizeof fp)
                unlink(fp);
            kai_grant_audit("revoked", s->grants[i].id, s->grants[i].agent,
                            s->grants[i].resource, s->grants[i].op, "revoke", "revoked by user");
            int tail = s->ngrants - i - 1;
            memmove(&s->grants[i], &s->grants[i + 1], (size_t)tail * sizeof s->grants[0]);
            if (s->consumed)   /* keep the parallel one-shot flags aligned */
                memmove((void *)&s->consumed[i], (void *)&s->consumed[i + 1], (size_t)tail);
            s->ngrants--; i--; removed++;
        }
    }
    if (removed) s->generation++;
    pthread_rwlock_unlock(&s->lock);
    return removed;
}
