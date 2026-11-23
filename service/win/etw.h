/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * The Watch service's ETW session: one real-time session ("Kai-Watch") with
 * Microsoft-Windows-Kernel-Process, -Kernel-Network, -DNS-Client and, only
 * when watch_files is on, -Kernel-File. Events go to the sink callbacks; the
 * sink holds the lock around src/watch.c.
 */
#ifndef KAI_ETW_H
#define KAI_ETW_H

#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

typedef struct {
    void (*process_start)(uint32_t pid, uint32_t ppid, uint64_t start, const char *image);
    void (*process_stop)(uint32_t pid, uint64_t start, uint64_t ts);
    void (*dns)(uint32_t pid, uint64_t ts, const char *name, const char *results);
    void (*connect)(uint32_t pid, uint64_t ts, const char *proto, const char *ip, int port);
    void (*file)(uint32_t pid, uint64_t ts, const char *path);
    /* cheap pre-check before an event is parsed */
    int (*pid_tagged)(uint32_t pid);
} kai_etw_sink;

typedef struct {
    int running;                 /* the consumer is delivering events */
    unsigned long events_lost;   /* lost by the session (ETW's count) */
    unsigned long buffers_lost;  /* real-time buffers the consumer missed */
    unsigned long events;        /* events seen by the callback */
    unsigned long by_provider[4];/* process, network, dns, file *events delivered* */
    unsigned long parsed[4];     /* ... and parsed (network/file: tagged PIDs only) */
    int files_on;
    char problem[200];           /* why it stopped, "" when fine */
} kai_etw_state;

/* Start the session and its consumer thread. 0 on success, else a Win32
 * error (and problem filled). Replaces a leftover session of the same name. */
int kai_etw_start(const kai_etw_sink *sink, int files_on);
/* Stop the session; the consumer thread ends. */
void kai_etw_stop(void);
/* Current state, with ETW's own loss counters (ControlTrace QUERY). */
void kai_etw_query(kai_etw_state *st);

/* NT device path ("\Device\HarddiskVolume3\Users\a") -> "C:/Users/a". */
int kai_etw_dos_path(const wchar_t *nt, char *out, size_t n);

#endif
