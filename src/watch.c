/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Watch: process tree (PID + start time), DNS attribution, protected-file
 * filter. See watch.h. No OS calls here: the Windows service (kaisvc) feeds
 * it ETW events, the tests feed it made-up ones.
 */
#include "watch.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define KW_BUCKETS 8192           /* Windows PIDs are multiples of 4 */
#define KW_DNS 4096               /* recent DNS answers kept */
#define KW_EXIT_SLACK (2 * KAI_TICKS_PER_SEC)   /* events delivered just after the exit */
#define KW_EXITED_KEEP (60 * KAI_TICKS_PER_SEC)
#define KW_DNS_KEEP (600 * KAI_TICKS_PER_SEC)

typedef struct {
    uint32_t pid, ppid, root_pid;
    uint64_t start, stop, root_start;   /* stop 0 = alive */
    unsigned gen;                       /* last snapshot that saw it */
    int used, next;                     /* next: same-bucket chain */
    int orphan;                         /* parent not known when it started */
    char agent[32], identity[96], image[64];
} kw_proc;

typedef struct {
    char ip[46], host[256];
    uint32_t pid, root_pid;
    uint64_t pstart, root_start, ts;
} kw_dns;

/* An event from a PID the tree doesn't know yet: ETW flushes each CPU's
 * buffer separately, so a short-lived child's connect can arrive before its
 * own start event. It waits here (at most KW_PENDING_KEEP) for that start. */
#define KW_PENDING 256
#define KW_PENDING_KEEP (5 * KAI_TICKS_PER_SEC)
typedef struct {
    int used, is_file;
    uint32_t pid;
    uint64_t ts;
    char proto[4], ip[46];
    int port;
    char *path;
} kw_pending;

struct kai_watch {
    kai_watch_ops ops;
    kw_proc *p;
    int n, cap, free_head;
    int bucket[KW_BUCKETS];
    kw_dns *dns;
    int dns_head, dns_count;
    unsigned gen;
    kai_watch_stats st;
    kw_pending pend[KW_PENDING];
    int npend;
    uint64_t latest;   /* newest event time seen */
};

static unsigned hash_pid(uint32_t pid) { return (pid >> 2) & (KW_BUCKETS - 1); }
static void flush_pending(kai_watch *w);
static void note_time(kai_watch *w, uint64_t ts);

static void copy(char *dst, size_t n, const char *src) {
    if (!n) return;
    size_t l = src ? strlen(src) : 0;
    if (l >= n) l = n - 1;
    if (l) memcpy(dst, src, l);
    dst[l] = '\0';
}

kai_watch *kai_watch_new(const kai_watch_ops *ops) {
    kai_watch *w = calloc(1, sizeof *w);
    if (!w) return NULL;
    if (ops) w->ops = *ops;
    for (int i = 0; i < KW_BUCKETS; i++) w->bucket[i] = -1;
    w->free_head = -1;
    w->dns = calloc(KW_DNS, sizeof *w->dns);
    if (!w->dns) { free(w); return NULL; }
    return w;
}

void kai_watch_free(kai_watch *w) {
    if (!w) return;
    for (int i = 0; i < KW_PENDING; i++) free(w->pend[i].path);
    free(w->p);
    free(w->dns);
    free(w);
}

/* The process that had this pid at ts (0: the live one). */
static kw_proc *find(kai_watch *w, uint32_t pid, uint64_t ts) {
    kw_proc *best = NULL;
    for (int i = w->bucket[hash_pid(pid)]; i >= 0; i = w->p[i].next) {
        kw_proc *c = &w->p[i];
        if (!c->used || c->pid != pid) continue;
        if (ts == 0) {
            if (c->stop) continue;
        } else {
            if (c->start > ts) continue;
            if (c->stop && ts > c->stop + KW_EXIT_SLACK) continue;
        }
        if (!best || c->start > best->start) best = c;
    }
    return best;
}

static kw_proc *find_exact(kai_watch *w, uint32_t pid, uint64_t start) {
    for (int i = w->bucket[hash_pid(pid)]; i >= 0; i = w->p[i].next)
        if (w->p[i].used && w->p[i].pid == pid && w->p[i].start == start) return &w->p[i];
    return NULL;
}

static kw_proc *alloc_proc(kai_watch *w) {
    int i;
    if (w->free_head >= 0) {
        i = w->free_head;
        w->free_head = w->p[i].next;
    } else {
        if (w->n == w->cap) {
            int nc = w->cap ? w->cap * 2 : 1024;
            kw_proc *np = realloc(w->p, (size_t)nc * sizeof *np);
            if (!np) return NULL;
            w->p = np;
            w->cap = nc;
        }
        i = w->n++;
    }
    memset(&w->p[i], 0, sizeof w->p[i]);
    w->p[i].used = 1;
    return &w->p[i];
}

static void link_proc(kai_watch *w, kw_proc *c) {
    unsigned b = hash_pid(c->pid);
    c->next = w->bucket[b];
    w->bucket[b] = (int)(c - w->p);
}

static const char *base_name(const char *path) {
    const char *b = path;
    for (const char *s = path; *s; s++)
        if (*s == '/' || *s == '\\') b = s + 1;
    return b;
}

static void inherit(kw_proc *c, const kw_proc *par) {
    copy(c->agent, sizeof c->agent, par->agent);
    copy(c->identity, sizeof c->identity, par->identity);
    c->root_pid = par->root_pid;
    c->root_start = par->root_start;
}

/* ETW delivers each CPU's buffer on its own, so a child's start event can
 * arrive before its parent's. When a tagged process turns up, children that
 * started after it with its PID as parent and no parent known yet are its
 * own: they take its tag, and so do theirs. */
static void adopt_orphans(kai_watch *w, const kw_proc *par, int depth) {
    if (depth > 32) return;
    for (int i = 0; i < w->n; i++) {
        kw_proc *c = &w->p[i];
        /* the first level waited for this parent (orphans); below it, children
         * found their parent but took no tag from it (it had none yet) */
        int waiting = c->orphan || (depth > 0 && !c->agent[0]);
        if (!c->used || !waiting || c->ppid != par->pid || c->start < par->start) continue;
        if (par->stop && c->start > par->stop + KW_EXIT_SLACK) continue;
        c->orphan = 0;
        if (c->agent[0] && c->root_pid == c->pid) continue;   /* an agent itself keeps its own tag */
        inherit(c, par);
        adopt_orphans(w, c, depth + 1);
    }
}

void kai_watch_process_start(kai_watch *w, uint32_t pid, uint32_t ppid, uint64_t start, const char *image) {
    if (!w) return;
    kw_proc *c = find_exact(w, pid, start);
    if (c) {   /* already known (a snapshot pass, or the event after a snapshot) */
        c->gen = w->gen;
        if (!c->image[0] && image) copy(c->image, sizeof c->image, base_name(image));
        return;
    }
    /* Any live process still holding this pid has exited (its stop event was lost). */
    for (kw_proc *old = find(w, pid, 0); old && old->start < start; old = find(w, pid, 0))
        old->stop = start;
    c = alloc_proc(w);
    if (!c) return;
    c->pid = pid;
    c->ppid = ppid;
    c->start = start;
    c->gen = w->gen;
    if (image) copy(c->image, sizeof c->image, base_name(image));
    char agent[32] = "", ident[96] = "";
    if (w->ops.classify && image && *image &&
        w->ops.classify(w->ops.ctx, pid, image, agent, sizeof agent, ident, sizeof ident) && agent[0]) {
        copy(c->agent, sizeof c->agent, agent);
        copy(c->identity, sizeof c->identity, ident);
        c->root_pid = pid;
        c->root_start = start;
    } else if (ppid != pid) {
        kw_proc *par = find(w, ppid, start);
        if (par && par->start <= start) {
            if (par->agent[0]) inherit(c, par);
        } else {
            c->orphan = 1;   /* its parent's start event may still be on its way */
        }
    }
    link_proc(w, c);
    if (c->agent[0]) adopt_orphans(w, c, 0);
    flush_pending(w);
}

void kai_watch_process_stop(kai_watch *w, uint32_t pid, uint64_t start, uint64_t ts) {
    if (!w) return;
    kw_proc *c = start ? find_exact(w, pid, start) : find(w, pid, 0);
    if (c && !c->stop) c->stop = ts ? ts : 1;
}

void kai_watch_sync_begin(kai_watch *w) {
    if (w) w->gen++;
}

void kai_watch_sync_end(kai_watch *w, uint64_t ts) {
    if (!w) return;
    for (int i = 0; i < w->n; i++)
        if (w->p[i].used && !w->p[i].stop && w->p[i].gen != w->gen) w->p[i].stop = ts ? ts : 1;
}

int kai_watch_tagged(kai_watch *w, uint32_t pid, uint64_t ts, char *agent, size_t n) {
    if (agent && n) agent[0] = '\0';
    kw_proc *c = w ? find(w, pid, ts) : NULL;
    if (!c || !c->agent[0]) return 0;
    if (agent) copy(agent, n, c->agent);
    return 1;
}

int kai_watch_pid_maybe_tagged(kai_watch *w, uint32_t pid) {
    if (!w) return 0;
    int alive = 0;
    for (int i = w->bucket[hash_pid(pid)]; i >= 0; i = w->p[i].next) {
        const kw_proc *c = &w->p[i];
        if (!c->used || c->pid != pid) continue;
        if (c->agent[0]) return 1;
        if (!c->stop) alive = 1;
    }
    return !alive;   /* not known yet: its start event may still be on its way */
}
/* ---------------------------------------------------------------- DNS */

static int is_ipv4(const char *s) {
    int dots = 0, digits = 0;
    for (; *s; s++) {
        if (*s == '.') { if (!digits) return 0; dots++; digits = 0; }
        else if (isdigit((unsigned char)*s)) { if (++digits > 3) return 0; }
        else return 0;
    }
    return dots == 3 && digits;
}

static int is_ipv6(const char *s) {
    int colons = 0;
    for (; *s; s++) {
        if (*s == ':') colons++;
        else if (!isxdigit((unsigned char)*s) && *s != '.') return 0;
    }
    return colons >= 2;
}

/* "::ffff:1.2.3.4" -> "1.2.3.4"; trims spaces; lower-cases IPv6. */
static int clean_ip(const char *in, char *out, size_t n) {
    while (*in == ' ') in++;
    if (!strncmp(in, "::ffff:", 7) && is_ipv4(in + 7)) in += 7;
    copy(out, n, in);
    size_t l = strlen(out);
    while (l && out[l - 1] == ' ') out[--l] = '\0';
    if (l > 1 && out[0] == '[' && out[l - 1] == ']') { memmove(out, out + 1, l - 2); out[l - 2] = '\0'; }
    if (is_ipv4(out)) return 1;
    if (!is_ipv6(out)) return 0;
    for (char *c = out; *c; c++) *c = (char)tolower((unsigned char)*c);
    if (!strncmp(out, "::ffff:", 7) && is_ipv4(out + 7)) memmove(out, out + 7, strlen(out + 7) + 1);
    return 1;
}

void kai_watch_dns(kai_watch *w, uint32_t pid, uint64_t ts, const char *name, const char *results) {
    if (!w || !name || !*name || !results) return;
    note_time(w, ts);
    kw_proc *c = find(w, pid, ts);
    const char *s = results;
    while (*s) {
        const char *e = strchr(s, ';');
        size_t l = e ? (size_t)(e - s) : strlen(s);
        char tok[96], ip[64];
        if (l < sizeof tok) {
            memcpy(tok, s, l);
            tok[l] = '\0';
            if (clean_ip(tok, ip, sizeof ip)) {
                kw_dns *d = &w->dns[w->dns_head];
                memset(d, 0, sizeof *d);
                copy(d->ip, sizeof d->ip, ip);
                copy(d->host, sizeof d->host, name);
                size_t hl = strlen(d->host);
                if (hl && d->host[hl - 1] == '.') d->host[hl - 1] = '\0';
                d->pid = pid;
                d->ts = ts;
                if (c) {
                    d->pstart = c->start;
                    d->root_pid = c->root_pid;
                    d->root_start = c->root_start;
                }
                w->dns_head = (w->dns_head + 1) % KW_DNS;
                if (w->dns_count < KW_DNS) w->dns_count++;
                w->st.dns_answers++;
            }
        }
        if (!e) break;
        s = e + 1;
    }
}

static const char *host_for(kai_watch *w, const kw_proc *c, const char *ip, uint64_t ts, const char **from) {
    const kw_dns *agent_hit = NULL, *any_hit = NULL;
    *from = NULL;
    for (int k = 0; k < w->dns_count; k++) {
        const kw_dns *d = &w->dns[(w->dns_head - 1 - k + KW_DNS) % KW_DNS];
        if (ts && d->ts + KW_DNS_KEEP < ts) continue;
        if (strcmp(d->ip, ip) != 0) continue;
        /* pstart 0: the lookup came before the process' start event did */
        if (d->pid == c->pid && (d->pstart == c->start || (!d->pstart && d->ts >= c->start))) {
            *from = "process";
            return d->host;
        }
        if (!agent_hit && c->root_pid && d->root_pid == c->root_pid && d->root_start == c->root_start)
            agent_hit = d;
        if (!any_hit) any_hit = d;
    }
    if (agent_hit) { *from = "agent"; return agent_hit->host; }
    if (any_hit) { *from = "machine"; return any_hit->host; }
    return NULL;
}

static void fill_event(kai_watch_event *e, const kw_proc *c, uint32_t pid, uint64_t ts) {
    memset(e, 0, sizeof *e);
    e->agent = c->agent;
    e->identity = c->identity;
    e->pid = pid;
    e->root_pid = c->root_pid;
    e->root_start = c->root_start;
    e->ts = ts;
    e->image = c->image;
}

static void note_time(kai_watch *w, uint64_t ts) {
    if (ts > w->latest) w->latest = ts;
}

static int pend(kai_watch *w, int is_file, uint32_t pid, uint64_t ts, const char *proto, const char *ip, int port,
                const char *path) {
    for (int i = 0; i < KW_PENDING; i++) {
        kw_pending *q = &w->pend[i];
        if (q->used) continue;
        memset(q, 0, sizeof *q);
        if (is_file && !(q->path = malloc(strlen(path) + 1))) return 0;
        q->used = 1;
        q->is_file = is_file;
        q->pid = pid;
        q->ts = ts;
        if (is_file) memcpy(q->path, path, strlen(path) + 1);
        else {
            copy(q->proto, sizeof q->proto, proto ? proto : "tcp");
            copy(q->ip, sizeof q->ip, ip);
            q->port = port;
        }
        w->npend++;
        return 1;
    }
    return 0;   /* full: dropped, as an untagged event would be */
}

static void deliver_connect(kai_watch *w, const kw_proc *c, uint32_t pid, uint64_t ts, const char *proto,
                            const char *cip, int port) {
    w->st.agent_connects++;
    kai_watch_event e;
    fill_event(&e, c, pid, ts);
    e.proto = proto ? proto : "tcp";
    e.ip = cip;
    e.port = port;
    e.host = host_for(w, c, cip, ts, &e.host_from);
    if (w->ops.on_connect) w->ops.on_connect(w->ops.ctx, &e);
}

static void deliver_file(kai_watch *w, const kw_proc *c, uint32_t pid, uint64_t ts, const char *path) {
    char rule[160] = "";
    if (!w->ops.file_protected || !w->ops.file_protected(w->ops.ctx, c->agent, path, rule, sizeof rule)) return;
    w->st.agent_files++;
    kai_watch_event e;
    fill_event(&e, c, pid, ts);
    e.path = path;
    e.rule = rule;
    if (w->ops.on_file) w->ops.on_file(w->ops.ctx, &e);
}

static void drop_pending(kai_watch *w, kw_pending *q) {
    free(q->path);
    q->path = NULL;
    q->used = 0;
    w->npend--;
}

/* Waiting events whose process is now known: delivered if it is tagged,
 * dropped if not; ones that waited too long are dropped. */
static void flush_pending(kai_watch *w) {
    if (!w->npend) return;
    for (int i = 0; i < KW_PENDING; i++) {
        kw_pending *q = &w->pend[i];
        if (!q->used) continue;
        kw_proc *c = find(w, q->pid, q->ts);
        if (c) {
            if (c->agent[0]) {
                if (q->is_file) deliver_file(w, c, q->pid, q->ts, q->path);
                else deliver_connect(w, c, q->pid, q->ts, q->proto, q->ip, q->port);
            }
            drop_pending(w, q);
        } else if (w->latest > q->ts + KW_PENDING_KEEP) {
            drop_pending(w, q);
        }
    }
}

void kai_watch_connect(kai_watch *w, uint32_t pid, uint64_t ts, const char *proto, const char *ip, int port) {
    if (!w || !ip) return;
    w->st.connects++;
    note_time(w, ts);
    char cip[64];
    if (!clean_ip(ip, cip, sizeof cip)) return;
    kw_proc *c = find(w, pid, ts);
    if (!c) { pend(w, 0, pid, ts, proto, cip, port, NULL); return; }   /* its start event may come next */
    if (!c->agent[0]) return;   /* untagged: never recorded */
    deliver_connect(w, c, pid, ts, proto, cip, port);
}

void kai_watch_file(kai_watch *w, uint32_t pid, uint64_t ts, const char *path) {
    if (!w || !path || !*path) return;
    w->st.file_events++;
    note_time(w, ts);
    kw_proc *c = find(w, pid, ts);
    if (!c) { pend(w, 1, pid, ts, NULL, NULL, 0, path); return; }
    if (!c->agent[0]) return;
    deliver_file(w, c, pid, ts, path);
}

void kai_watch_gc(kai_watch *w, uint64_t now) {
    if (!w) return;
    if (now > w->latest) w->latest = now;
    flush_pending(w);
    for (int b = 0; b < KW_BUCKETS; b++) {
        int *link = &w->bucket[b];
        while (*link >= 0) {
            kw_proc *c = &w->p[*link];
            if (c->stop && now > c->stop + KW_EXITED_KEEP) {
                int idx = *link;
                *link = c->next;
                c->used = 0;
                c->next = w->free_head;
                w->free_head = idx;
            } else {
                link = &c->next;
            }
        }
    }
    while (w->dns_count > 0) {   /* drop the oldest answers past their keep time */
        kw_dns *d = &w->dns[(w->dns_head - w->dns_count + KW_DNS) % KW_DNS];
        if (d->ts + KW_DNS_KEEP >= now) break;
        w->dns_count--;
    }
}

void kai_watch_get_stats(kai_watch *w, kai_watch_stats *s) {
    if (!w || !s) return;
    *s = w->st;
    s->procs = s->tagged = 0;
    for (int i = 0; i < w->n; i++) {
        if (!w->p[i].used || w->p[i].stop) continue;
        s->procs++;
        if (w->p[i].agent[0]) s->tagged++;
    }
}
