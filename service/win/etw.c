/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * The Watch service's ETW session. See etw.h.
 *
 * Cost control (the budget is under 1% CPU on an idle machine):
 * - each provider is enabled with an event-ID filter, so ETW drops every
 *   other event in the kernel: process start/stop (1, 2), TCP connect and UDP
 *   send (12, 28, 42, 58), DNS query completed (3008), file create (12);
 * - network and file events are checked against the tagged-PID set before
 *   anything is parsed (the PID is the first field of every Kernel-Network
 *   event, and file creates run in the caller's context);
 * - only process and DNS events are parsed for every process (low volume;
 *   DNS answers from any process are kept so a hostname looked up by the DNS
 *   service can still name an agent's connection, marked as the machine's).
 */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <evntrace.h>
#include <evntcons.h>
#include <tdh.h>

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "etw.h"

static const wchar_t SESSION[] = L"Kai-Watch";
/* {6B3D6A7C-2F0E-4E5B-9C2A-4B61D1A2C0DE}: this session's own GUID */
static const GUID SESSION_GUID = {0x6b3d6a7c, 0x2f0e, 0x4e5b, {0x9c, 0x2a, 0x4b, 0x61, 0xd1, 0xa2, 0xc0, 0xde}};
static const GUID KERNEL_PROCESS = {0x22fb2cd6, 0x0e7b, 0x422b, {0xa0, 0xc7, 0x2f, 0xad, 0x1f, 0xd0, 0xe7, 0x16}};
static const GUID KERNEL_NETWORK = {0x7dd42a49, 0x5329, 0x4832, {0x8d, 0xfd, 0x43, 0xd9, 0x79, 0x15, 0x3a, 0x88}};
static const GUID DNS_CLIENT = {0x1c95126e, 0x7eea, 0x49a9, {0xa3, 0xfe, 0xa3, 0x78, 0xb0, 0x3d, 0xdb, 0x4d}};
static const GUID KERNEL_FILE = {0xedd08927, 0x9cc4, 0x4e65, {0xb9, 0x70, 0xc2, 0x56, 0x0f, 0xb5, 0xc2, 0x89}};

#define KW_PROCESS_KEYWORD 0x10ULL       /* WINEVENT_KEYWORD_PROCESS */
#define KN_KEYWORDS 0x30ULL              /* KERNEL_NETWORK_KEYWORD_IPV4 | _IPV6 */
#define KF_CREATE_KEYWORD 0x80ULL        /* KERNEL_FILE_KEYWORD_CREATE */

static kai_etw_sink g_sink;
static TRACEHANDLE g_session;
static TRACEHANDLE g_trace = INVALID_PROCESSTRACE_HANDLE;
static HANDLE g_thread;
static volatile LONG g_running, g_stopping, g_events;
static volatile LONG g_by[4], g_parsed[4];
unsigned long g_dns_bad[4];   /* diagnostics: no status, failed, no name, no results */
unsigned long g_dns_status[8]; /* the last failure statuses (Win32/DNS error codes) */
unsigned long g_dns_ids[3];    /* 3008 query completed, 3018 cache lookup, 3020 response */
static int g_files_on;
static char g_problem[200];
static SRWLOCK g_lock = SRWLOCK_INIT;

typedef struct {
    EVENT_TRACE_PROPERTIES p;
    wchar_t name[64];
} props_t;

static void props_init(props_t *pp) {
    memset(pp, 0, sizeof *pp);
    pp->p.Wnode.BufferSize = sizeof *pp;
    pp->p.Wnode.Flags = WNODE_FLAG_TRACED_GUID;
    pp->p.Wnode.ClientContext = 1;   /* QPC; the consumer converts to FILETIME */
    pp->p.Wnode.Guid = SESSION_GUID;
    pp->p.LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
    pp->p.BufferSize = 64;           /* KB */
    pp->p.MinimumBuffers = 4;
    pp->p.MaximumBuffers = 64;
    pp->p.FlushTimer = 1;            /* seconds */
    pp->p.LoggerNameOffset = (ULONG)offsetof(props_t, name);
}

static void set_problem(const char *fmt, unsigned long code) {
    AcquireSRWLockExclusive(&g_lock);
    snprintf(g_problem, sizeof g_problem, fmt, code);
    ReleaseSRWLockExclusive(&g_lock);
}

/* ---------------------------------------------------------- device paths */

typedef struct { wchar_t dev[160]; size_t len; char drive; } devmap_t;
static devmap_t g_map[26];
static int g_nmap;
static ULONGLONG g_map_built;
static SRWLOCK g_map_lock = SRWLOCK_INIT;

static void build_map(void) {
    AcquireSRWLockExclusive(&g_map_lock);
    g_nmap = 0;
    for (wchar_t c = L'A'; c <= L'Z'; c++) {
        wchar_t drive[3] = {c, L':', 0}, target[160];
        if (!QueryDosDeviceW(drive, target, 160)) continue;
        devmap_t *m = &g_map[g_nmap++];
        wcsncpy(m->dev, target, 159);
        m->dev[159] = 0;
        m->len = wcslen(m->dev);
        m->drive = (char)c;
    }
    g_map_built = GetTickCount64();
    ReleaseSRWLockExclusive(&g_map_lock);
}

static int utf8(const wchar_t *w, char *out, size_t n) {
    int r = WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)n, NULL, NULL);
    if (r <= 0) { if (n) out[0] = '\0'; return -1; }
    return 0;
}

static void fwd_slashes(char *s) {
    for (; *s; s++) if (*s == '\\') *s = '/';
}

int kai_etw_dos_path(const wchar_t *nt, char *out, size_t n) {
    if (!nt || !n) return -1;
    out[0] = '\0';
    if (!wcsncmp(nt, L"\\??\\", 4)) nt += 4;
    if (iswalpha(nt[0]) && nt[1] == L':') {
        if (utf8(nt, out, n)) return -1;
        fwd_slashes(out);
        return 0;
    }
    if (!_wcsnicmp(nt, L"\\Device\\Mup\\", 12)) {
        char rest[1024];
        if (utf8(nt + 12, rest, sizeof rest)) return -1;
        fwd_slashes(rest);
        snprintf(out, n, "//%s", rest);
        return 0;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
        AcquireSRWLockShared(&g_map_lock);
        for (int i = 0; i < g_nmap; i++) {
            const devmap_t *m = &g_map[i];
            if (_wcsnicmp(nt, m->dev, m->len) != 0 || (nt[m->len] != L'\\' && nt[m->len] != 0)) continue;
            char rest[1024];
            int bad = utf8(nt + m->len, rest, sizeof rest);
            char d = m->drive;
            ReleaseSRWLockShared(&g_map_lock);
            if (bad) return -1;
            fwd_slashes(rest);
            snprintf(out, n, "%c:%s", d, rest[0] ? rest : "/");
            return 0;
        }
        ReleaseSRWLockShared(&g_map_lock);
        /* a drive mounted since: rebuild, at most once a minute */
        if (attempt == 0 && GetTickCount64() - g_map_built > 60000) build_map();
        else break;
    }
    return -1;
}

/* ------------------------------------------------------------ properties */

static int prop(PEVENT_RECORD e, const wchar_t *name, void *buf, ULONG n, ULONG *got) {
    PROPERTY_DATA_DESCRIPTOR d;
    d.PropertyName = (ULONGLONG)(ULONG_PTR)name;
    d.ArrayIndex = ULONG_MAX;
    d.Reserved = 0;
    ULONG sz = 0;
    if (TdhGetPropertySize(e, 0, NULL, 1, &d, &sz) != ERROR_SUCCESS || sz == 0 || sz > n) return -1;
    if (TdhGetProperty(e, 0, NULL, 1, &d, sz, (PBYTE)buf) != ERROR_SUCCESS) return -1;
    if (got) *got = sz;
    return 0;
}

static int prop_u32(PEVENT_RECORD e, const wchar_t *name, uint32_t *v) {
    ULONG got = 0;
    BYTE b[8] = {0};
    if (prop(e, name, b, sizeof b, &got) || (got != 4 && got != 2)) return -1;
    *v = got == 4 ? *(uint32_t *)b : *(uint16_t *)b;
    return 0;
}

static int prop_u64(PEVENT_RECORD e, const wchar_t *name, uint64_t *v) {
    ULONG got = 0;
    uint64_t x = 0;
    if (prop(e, name, &x, sizeof x, &got) || got != 8) return -1;
    *v = x;
    return 0;
}

static int prop_wstr(PEVENT_RECORD e, const wchar_t *name, wchar_t *buf, size_t chars) {
    ULONG got = 0;
    if (prop(e, name, buf, (ULONG)((chars - 1) * sizeof(wchar_t)), &got)) return -1;
    buf[got / sizeof(wchar_t)] = 0;
    return 0;
}

/* ---------------------------------------------------------------- events */

static void on_process(PEVENT_RECORD e, USHORT id, uint64_t ts) {
    uint32_t pid = 0, ppid = 0;
    uint64_t start = 0;
    if (prop_u32(e, L"ProcessID", &pid)) return;
    prop_u64(e, L"CreateTime", &start);
    if (id == 1) {
        static wchar_t img[1024];   /* the callback runs on one thread */
        char dos[1100] = "";
        prop_u32(e, L"ParentProcessID", &ppid);
        if (!prop_wstr(e, L"ImageName", img, 1024)) kai_etw_dos_path(img, dos, sizeof dos);
        if (dos[0]) InterlockedIncrement(&g_parsed[0]);
        if (g_sink.process_start) g_sink.process_start(pid, ppid, start ? start : ts, dos[0] ? dos : NULL);
    } else if (id == 2) {
        if (g_sink.process_stop) g_sink.process_stop(pid, start, ts);
    }
}

static void on_network(PEVENT_RECORD e, USHORT id, uint64_t ts) {
    if (e->UserDataLength < 4) return;
    uint32_t pid = *(const uint32_t *)e->UserData;   /* first field of every Kernel-Network event */
    if (!g_sink.pid_tagged || !g_sink.pid_tagged(pid)) return;
    int v6 = id == 28 || id == 58, udp = id == 42 || id == 58;
    BYTE addr[16];
    ULONG got = 0;
    uint32_t port = 0;
    if (prop(e, L"daddr", addr, sizeof addr, &got) || got != (v6 ? 16u : 4u)) return;
    if (prop_u32(e, L"dport", &port)) return;
    char ip[64] = "";
    if (!InetNtopA(v6 ? AF_INET6 : AF_INET, addr, ip, sizeof ip)) return;
    port = ntohs((u_short)port);
    InterlockedIncrement(&g_parsed[1]);
    if (g_sink.connect) g_sink.connect(pid, ts, udp ? "udp" : "tcp", ip, (int)port);
}

static void on_dns(PEVENT_RECORD e, uint64_t ts) {
    static wchar_t name[512], results[2048];
    uint32_t status = 1;
    USHORT id = e->EventHeader.EventDescriptor.Id;
    g_dns_ids[id == 3008 ? 0 : id == 3018 ? 1 : 2]++;
    if (prop_u32(e, L"QueryStatus", &status) && prop_u32(e, L"Status", &status)) { g_dns_bad[0]++; return; }
    if (status != 0) { g_dns_bad[1]++; g_dns_status[g_dns_bad[1] % 8] = status; return; }
    if (prop_wstr(e, L"QueryName", name, 512)) { g_dns_bad[2]++; return; }
    if (prop_wstr(e, L"QueryResults", results, 2048)) { g_dns_bad[3]++; return; }
    char n8[600], r8[2400];
    if (utf8(name, n8, sizeof n8) || utf8(results, r8, sizeof r8)) return;
    InterlockedIncrement(&g_parsed[2]);
    if (g_sink.dns) g_sink.dns(e->EventHeader.ProcessId, ts, n8, r8);
}

static void on_file(PEVENT_RECORD e, uint64_t ts) {
    uint32_t pid = e->EventHeader.ProcessId;
    if (!g_sink.pid_tagged || !g_sink.pid_tagged(pid)) return;
    uint32_t opts = 0;
    if (!prop_u32(e, L"CreateOptions", &opts) && (opts & 0x1)) return;   /* FILE_DIRECTORY_FILE */
    static wchar_t nt[1024];
    char dos[1100];
    if (prop_wstr(e, L"FileName", nt, 1024) || kai_etw_dos_path(nt, dos, sizeof dos)) return;
    InterlockedIncrement(&g_parsed[3]);
    if (g_sink.file) g_sink.file(pid, ts, dos);
}

static void WINAPI on_event(PEVENT_RECORD e) {
    InterlockedIncrement(&g_events);
    const GUID *g = &e->EventHeader.ProviderId;
    USHORT id = e->EventHeader.EventDescriptor.Id;
    uint64_t ts = (uint64_t)e->EventHeader.TimeStamp.QuadPart;   /* FILETIME: not raw-timestamp mode */
    if (IsEqualGUID(g, &KERNEL_NETWORK)) {
        InterlockedIncrement(&g_by[1]);
        if (id == 12 || id == 28 || id == 42 || id == 58) on_network(e, id, ts);
    } else if (IsEqualGUID(g, &KERNEL_PROCESS)) {
        InterlockedIncrement(&g_by[0]);
        if (id == 1 || id == 2) on_process(e, id, ts);
    } else if (IsEqualGUID(g, &DNS_CLIENT)) {
        InterlockedIncrement(&g_by[2]);
        if (id == 3008 || id == 3018 || id == 3020) on_dns(e, ts);
    } else if (IsEqualGUID(g, &KERNEL_FILE)) {
        InterlockedIncrement(&g_by[3]);
        if (id == 12 && g_files_on) on_file(e, ts);
    }
}

/* ------------------------------------------------------------- session */

static ULONG enable(const GUID *g, UCHAR level, ULONGLONG any, const USHORT *ids, USHORT nids) {
    ENABLE_TRACE_PARAMETERS ep;
    memset(&ep, 0, sizeof ep);
    ep.Version = ENABLE_TRACE_PARAMETERS_VERSION_2;
    union { EVENT_FILTER_EVENT_ID f; BYTE raw[sizeof(EVENT_FILTER_EVENT_ID) + 8 * sizeof(USHORT)]; } fb;
    EVENT_FILTER_DESCRIPTOR fd;
    if (nids && nids <= 8) {
        memset(&fb, 0, sizeof fb);
        fb.f.FilterIn = TRUE;
        fb.f.Count = nids;
        memcpy(fb.f.Events, ids, nids * sizeof(USHORT));
        fd.Ptr = (ULONGLONG)(ULONG_PTR)&fb;
        fd.Size = (ULONG)(offsetof(EVENT_FILTER_EVENT_ID, Events) + nids * sizeof(USHORT));
        fd.Type = EVENT_FILTER_TYPE_EVENT_ID;
        ep.EnableFilterDesc = &fd;
        ep.FilterDescCount = 1;
    }
    ULONG r = EnableTraceEx2(g_session, g, EVENT_CONTROL_CODE_ENABLE_PROVIDER, level, any, 0, 0, &ep);
    if (r != ERROR_SUCCESS && nids) {   /* no event-ID filtering here: enable unfiltered */
        ep.EnableFilterDesc = NULL;
        ep.FilterDescCount = 0;
        r = EnableTraceEx2(g_session, g, EVENT_CONTROL_CODE_ENABLE_PROVIDER, level, any, 0, 0, &ep);
    }
    return r;
}

static DWORD WINAPI consumer(LPVOID arg) {
    (void)arg;
    EVENT_TRACE_LOGFILEW lf;
    memset(&lf, 0, sizeof lf);
    lf.LoggerName = (LPWSTR)SESSION;
    lf.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    lf.EventRecordCallback = on_event;
    g_trace = OpenTraceW(&lf);
    if (g_trace == INVALID_PROCESSTRACE_HANDLE) {
        set_problem("couldn't read the ETW session (error %lu)", GetLastError());
        return 1;
    }
    InterlockedExchange(&g_running, 1);
    ULONG r = ProcessTrace(&g_trace, 1, NULL, NULL);
    InterlockedExchange(&g_running, 0);
    if (!g_stopping) set_problem("the ETW session ended (error %lu)", r);
    CloseTrace(g_trace);
    g_trace = INVALID_PROCESSTRACE_HANDLE;
    return 0;
}

static void stop_named(void) {
    props_t pp;
    props_init(&pp);
    ControlTraceW(0, SESSION, &pp.p, EVENT_TRACE_CONTROL_STOP);
}

int kai_etw_start(const kai_etw_sink *sink, int files_on) {
    kai_etw_stop();
    g_sink = *sink;
    g_files_on = files_on;
    g_stopping = 0;
    InterlockedExchange(&g_events, 0);
    for (int i = 0; i < 4; i++) { InterlockedExchange(&g_by[i], 0); InterlockedExchange(&g_parsed[i], 0); }
    AcquireSRWLockExclusive(&g_lock);
    g_problem[0] = 0;
    ReleaseSRWLockExclusive(&g_lock);
    build_map();
    stop_named();   /* a session left over from a crash */
    props_t pp;
    props_init(&pp);
    ULONG r = StartTraceW(&g_session, SESSION, &pp.p);
    if (r != ERROR_SUCCESS) {
        set_problem(r == ERROR_ACCESS_DENIED ? "Windows refused the ETW session (error %lu): Kai Watch must run "
                                               "as a service or as administrator"
                                             : "couldn't start the ETW session (error %lu)", r);
        g_session = 0;
        return (int)r;
    }
    static const USHORT proc_ids[] = {1, 2}, net_ids[] = {12, 28, 42, 58}, dns_ids[] = {3008, 3018, 3020}, file_ids[] = {12};
    ULONG e1 = enable(&KERNEL_PROCESS, TRACE_LEVEL_INFORMATION, KW_PROCESS_KEYWORD, proc_ids, 2);
    ULONG e2 = enable(&KERNEL_NETWORK, TRACE_LEVEL_INFORMATION, KN_KEYWORDS, net_ids, 4);
    ULONG e3 = enable(&DNS_CLIENT, TRACE_LEVEL_VERBOSE, ~0ULL, dns_ids, 3);
    ULONG e4 = files_on ? enable(&KERNEL_FILE, TRACE_LEVEL_INFORMATION, KF_CREATE_KEYWORD, file_ids, 1) : 0;
    if (e1 || e2 || e3 || e4) {
        ULONG bad = e1 ? e1 : e2 ? e2 : e3 ? e3 : e4;
        set_problem("couldn't enable an ETW provider (error %lu)", bad);
        kai_etw_stop();
        return (int)bad;
    }
    g_thread = CreateThread(NULL, 0, consumer, NULL, 0, NULL);
    if (!g_thread) {
        set_problem("couldn't start the ETW reader (error %lu)", GetLastError());
        kai_etw_stop();
        return 1;
    }
    for (int i = 0; i < 50 && !g_running && WaitForSingleObject(g_thread, 0) == WAIT_TIMEOUT; i++) Sleep(20);
    return 0;
}

void kai_etw_stop(void) {
    g_stopping = 1;
    if (g_session) {
        props_t pp;
        props_init(&pp);
        ControlTraceW(g_session, NULL, &pp.p, EVENT_TRACE_CONTROL_STOP);
        g_session = 0;
    }
    if (g_thread) {
        if (WaitForSingleObject(g_thread, 5000) == WAIT_TIMEOUT && g_trace != INVALID_PROCESSTRACE_HANDLE)
            CloseTrace(g_trace);
        WaitForSingleObject(g_thread, 2000);
        CloseHandle(g_thread);
        g_thread = NULL;
    }
    InterlockedExchange(&g_running, 0);
}

void kai_etw_query(kai_etw_state *st) {
    memset(st, 0, sizeof *st);
    st->running = g_running && g_session;
    st->events = (unsigned long)g_events;
    st->files_on = g_files_on;
    for (int i = 0; i < 4; i++) { st->by_provider[i] = (unsigned long)g_by[i]; st->parsed[i] = (unsigned long)g_parsed[i]; }
    if (g_session) {
        props_t pp;
        props_init(&pp);
        if (ControlTraceW(g_session, NULL, &pp.p, EVENT_TRACE_CONTROL_QUERY) == ERROR_SUCCESS) {
            st->events_lost = pp.p.EventsLost;
            st->buffers_lost = pp.p.RealTimeBuffersLost;
        } else {
            st->running = 0;
            if (!g_problem[0]) set_problem("the ETW session is gone (error %lu)", GetLastError());
        }
    }
    AcquireSRWLockShared(&g_lock);
    memcpy(st->problem, g_problem, sizeof st->problem);
    ReleaseSRWLockShared(&g_lock);
    if (st->running) st->problem[0] = '\0';
}
