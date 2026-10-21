/*
 * Kai — storage ES-handler profiler.
 * Copyright (C) 2026 The Kai Authors.
 * SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Aggregates per-stage timing for the Endpoint Security authorization
 * callback. Design constraints (the auth path runs for every agent file op,
 * possibly on several ES threads at once):
 *
 *   - lock-free: counters are C11 atomics with relaxed ordering, so no lock is
 *     taken and no contention is added to the hot path;
 *   - zero-allocation: all state is static, fixed-size;
 *   - no blocking I/O: recording never writes to disk — export is a separate,
 *     caller-driven snapshot that runs off the hot path;
 *   - off by default and a single relaxed load when disabled, so leaving it
 *     compiled in costs effectively nothing.
 *
 * Latency distribution is kept as a power-of-two histogram (bucket b holds
 * durations in [2^(b-1), 2^b) ns), which is bounded and allocation-free;
 * percentiles are therefore reported to the nearest power-of-two bucket edge
 * (approximate by construction — this is a profiler, not an SLA meter). The
 * exact maximum and the exact mean are tracked alongside it.
 */
#include "kai.h"

#include <stdatomic.h>
#include <stdio.h>

/* 48 buckets cover 1 ns .. 2^47 ns (~39 h), far beyond any ES deadline. */
#define KAI_PROF_NBUCKETS 48

struct kai_prof_stage_stats {
    _Atomic uint64_t count;
    _Atomic uint64_t sum_ns;                    /* for the exact mean         */
    _Atomic uint64_t max_ns;                    /* exact maximum              */
    _Atomic uint64_t bucket[KAI_PROF_NBUCKETS]; /* power-of-two histogram     */
};

static atomic_int g_enabled = 0;
static struct kai_prof_stage_stats g_stage[KAI_PROF_NSTAGES];

void kai_prof_set_enabled(int on) {
    atomic_store_explicit(&g_enabled, on ? 1 : 0, memory_order_relaxed);
}

int kai_prof_enabled(void) {
    return atomic_load_explicit(&g_enabled, memory_order_relaxed);
}

/* floor(log2(ns)) + 1, clamped to the table; ns == 0 -> bucket 0. */
static int kai_prof_bucket(uint64_t ns) {
    int b = 0;
    while (ns && b < KAI_PROF_NBUCKETS - 1) { ns >>= 1; b++; }
    return b;
}

void kai_prof_record(int stage, uint64_t ns) {
    if (!atomic_load_explicit(&g_enabled, memory_order_relaxed)) return;
    if (stage < 0 || stage >= KAI_PROF_NSTAGES) return;
    struct kai_prof_stage_stats *s = &g_stage[stage];
    atomic_fetch_add_explicit(&s->count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->sum_ns, ns, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->bucket[kai_prof_bucket(ns)], 1, memory_order_relaxed);
    /* Exact max via a relaxed CAS loop; a lost race only undercounts a tie. */
    uint64_t cur = atomic_load_explicit(&s->max_ns, memory_order_relaxed);
    while (ns > cur &&
           !atomic_compare_exchange_weak_explicit(&s->max_ns, &cur, ns,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) { }
}

void kai_prof_reset(void) {
    for (int i = 0; i < KAI_PROF_NSTAGES; i++) {
        atomic_store_explicit(&g_stage[i].count, 0, memory_order_relaxed);
        atomic_store_explicit(&g_stage[i].sum_ns, 0, memory_order_relaxed);
        atomic_store_explicit(&g_stage[i].max_ns, 0, memory_order_relaxed);
        for (int b = 0; b < KAI_PROF_NBUCKETS; b++)
            atomic_store_explicit(&g_stage[i].bucket[b], 0, memory_order_relaxed);
    }
}

/* Upper edge (ns) of the bucket the q-quantile falls in, from a snapshot. */
static uint64_t kai_prof_quantile_ns(const uint64_t *bucket, uint64_t count, double q) {
    if (count == 0) return 0;
    uint64_t target = (uint64_t)(q * (double)count);
    if (target == 0) target = 1;
    uint64_t cum = 0;
    for (int b = 0; b < KAI_PROF_NBUCKETS; b++) {
        cum += bucket[b];
        if (cum >= target)
            return b == 0 ? 0 : ((uint64_t)1 << b); /* upper edge of [2^(b-1),2^b) */
    }
    return (uint64_t)1 << (KAI_PROF_NBUCKETS - 1);
}

static const char *const KAI_PROF_STAGE_NAME[KAI_PROF_NSTAGES] = {
    "total", "classify", "path", "policy", "respond", "deadline_margin",
};

size_t kai_prof_export_json(char *buf, size_t buflen) {
    /* Build into a local buffer so a short caller buffer can't truncate JSON
     * mid-number; copy the prefix out and report the full length needed. */
    char tmp[2048];
    size_t n = 0;
    #define KAI_PROF_APPEND(...) \
        do { int w = snprintf(tmp + n, sizeof(tmp) > n ? sizeof(tmp) - n : 0, __VA_ARGS__); \
             if (w > 0) n += (size_t)w; } while (0)

    KAI_PROF_APPEND("{\"enabled\":%d,\"unit\":\"us\",\"note\":\"percentiles are "
                    "power-of-two bucket edges (approx); avg and max exact\","
                    "\"stages\":{", kai_prof_enabled());
    for (int i = 0; i < KAI_PROF_NSTAGES; i++) {
        struct kai_prof_stage_stats *s = &g_stage[i];
        uint64_t count = atomic_load_explicit(&s->count, memory_order_relaxed);
        uint64_t sum = atomic_load_explicit(&s->sum_ns, memory_order_relaxed);
        uint64_t mx = atomic_load_explicit(&s->max_ns, memory_order_relaxed);
        uint64_t snap[KAI_PROF_NBUCKETS];
        for (int b = 0; b < KAI_PROF_NBUCKETS; b++)
            snap[b] = atomic_load_explicit(&s->bucket[b], memory_order_relaxed);
        double avg = count ? (double)sum / (double)count : 0.0;
        double p95 = (double)kai_prof_quantile_ns(snap, count, 0.95);
        double p99 = (double)kai_prof_quantile_ns(snap, count, 0.99);
        KAI_PROF_APPEND("%s\"%s\":{\"count\":%llu,\"avg\":%.3f,\"p95\":%.3f,"
                        "\"p99\":%.3f,\"max\":%.3f}",
                        i ? "," : "", KAI_PROF_STAGE_NAME[i],
                        (unsigned long long)count, avg / 1000.0, p95 / 1000.0,
                        p99 / 1000.0, (double)mx / 1000.0);
    }
    KAI_PROF_APPEND("}}");
    #undef KAI_PROF_APPEND

    if (buf && buflen) {
        size_t copy = n < buflen ? n : buflen - 1;
        for (size_t i = 0; i < copy; i++) buf[i] = tmp[i];
        buf[copy] = '\0';
    }
    return n; /* full length needed, excluding the NUL */
}
