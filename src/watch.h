/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Watch: the process tree, DNS attribution and protected-file filter behind
 * the Windows Watch service (kaisvc). Portable C with no OS calls, so it is
 * unit-tested without ETW: the service feeds it process, DNS, connect and
 * file-open events and gets back only what belongs to an agent.
 *
 * Processes are keyed by PID plus start time (100 ns ticks), never PID
 * alone: Windows reuses PIDs quickly, and an event is matched to the process
 * that had that PID when the event happened. A process is tagged when it is
 * a known agent (the service's classify callback: image path, command line,
 * Authenticode signer) or descends from one; the nearest agent above it
 * names the tag. Untagged processes never reach a callback.
 *
 * Hostnames: a connection to an address gets the name from the newest DNS
 * answer for that address made by the same process, else by the same agent's
 * tree, else by any process on this machine ("host_from" says which). An
 * address nobody looked up stays an address.
 *
 * ETW delivers each CPU's buffer on its own, so events don't arrive in order:
 * a child's start event can come before its parent's (the parent's tag is
 * passed down when it arrives), and a connect before its own process' start
 * event (it waits up to 5 s for it, then is dropped).
 */
#ifndef KAI_WATCH_H
#define KAI_WATCH_H

#include <stddef.h>
#include <stdint.h>

typedef struct kai_watch kai_watch;

typedef struct {
    const char *agent;      /* tag: the agent this process is (or runs under) */
    const char *identity;   /* the agent's verified signer, "" when unknown */
    uint32_t pid;           /* the process the event came from */
    uint32_t root_pid;      /* the agent process it runs under */
    uint64_t root_start;
    uint64_t ts;            /* event time, 100 ns ticks */
    const char *image;      /* the process' program name (base name) */
    /* connections */
    const char *proto;      /* "tcp" or "udp" */
    const char *ip;         /* printable address, IPv6 without brackets */
    int port;
    const char *host;       /* NULL when no DNS answer named the address */
    const char *host_from;  /* "process", "agent", "machine" or NULL */
    /* file opens */
    const char *path;       /* protected path (DOS form, '/' separators) */
    const char *rule;       /* what made it protected (kai_path_protected's why) */
} kai_watch_event;

typedef struct {
    void *ctx;
    /* Is this new process an agent? Fill agent (and identity) and return 1.
     * image is the full program path, '/'-separated. */
    int (*classify)(void *ctx, uint32_t pid, const char *image, char *agent, size_t an,
                    char *identity, size_t in);
    /* A tagged process connected. */
    void (*on_connect)(void *ctx, const kai_watch_event *e);
    /* A tagged process opened a file: return 1 (and fill rule) when it is
     * protected for that agent; only then on_file is called. */
    int (*file_protected)(void *ctx, const char *agent, const char *path, char *rule, size_t n);
    void (*on_file)(void *ctx, const kai_watch_event *e);
} kai_watch_ops;

typedef struct {
    long procs, tagged, dns_answers;
    long connects, agent_connects, file_events, agent_files;
} kai_watch_stats;

kai_watch *kai_watch_new(const kai_watch_ops *ops);
void kai_watch_free(kai_watch *w);

/* image: full path ('/' or '\'), or NULL when unknown. */
void kai_watch_process_start(kai_watch *w, uint32_t pid, uint32_t ppid, uint64_t start, const char *image);
void kai_watch_process_stop(kai_watch *w, uint32_t pid, uint64_t start, uint64_t ts);
/* A snapshot pass is starting / done: processes not seen again in it are
 * marked exited at ts (event-loss recovery). */
void kai_watch_sync_begin(kai_watch *w);
void kai_watch_sync_end(kai_watch *w, uint64_t ts);

/* results: the DNS client's answer list, ';'-separated; tokens that aren't
 * addresses (CNAMEs, "type: 5 ...") are skipped; "::ffff:a.b.c.d" is a.b.c.d. */
void kai_watch_dns(kai_watch *w, uint32_t pid, uint64_t ts, const char *name, const char *results);
void kai_watch_connect(kai_watch *w, uint32_t pid, uint64_t ts, const char *proto, const char *ip, int port);
void kai_watch_file(kai_watch *w, uint32_t pid, uint64_t ts, const char *path);

/* Is pid (as it was at ts; ts 0 = now/alive) tagged? Fills agent. */
int kai_watch_tagged(kai_watch *w, uint32_t pid, uint64_t ts, char *agent, size_t n);
/* A cheap pre-check for the event loop: is an event from this pid worth parsing?
 * Yes when a process with this pid is tagged, or when no live process has it
 * (its start event may still be on its way: the event then waits, up to 5 s,
 * for it). */
int kai_watch_pid_maybe_tagged(kai_watch *w, uint32_t pid);

/* Drop exited processes older than 60 s and DNS answers older than 10 minutes. */
void kai_watch_gc(kai_watch *w, uint64_t now);
void kai_watch_get_stats(kai_watch *w, kai_watch_stats *s);

#define KAI_TICKS_PER_SEC 10000000ULL

#endif
