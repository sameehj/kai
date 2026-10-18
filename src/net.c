/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Network wall helpers: the egress allowlist and a TLS ClientHello parser
 * that finds the server name (SNI). The network extension sees most flows as
 * a bare IP address, so the hostname comes from the first bytes the client
 * sends. Everything here runs on untrusted input: every read is bounds-checked.
 */
#include "internal.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

/* host == entry, or host ends with "." + entry. Case-insensitive. */
static int host_covered(const char *host, const char *entry) {
    size_t hl = strlen(host), el = strlen(entry);
    while (hl && host[hl - 1] == '.') hl--; /* "example.com." is a valid FQDN */
    if (!el || el > hl) return 0;
    if (strncasecmp(host + hl - el, entry, el) != 0) return 0;
    return hl == el || host[hl - el - 1] == '.';
}

/* An allowlist entry, split: a host name, or an address with a prefix
 * length (a single address is a full-length prefix), and an optional port.
 *   example.com   example.com:5432   10.0.0.0/8   203.0.113.5:22
 *   2001:db8::/32   [2001:db8::1]:22 */
typedef struct {
    char host[256];      /* host name, or "" for an address entry */
    unsigned char addr[16];
    int family;          /* AF_INET / AF_INET6 for an address entry */
    int bits;            /* prefix length */
    int port;            /* 0 = any port */
} egress_entry;

static int parse_port(const char *s) {
    char *end;
    long v = strtol(s, &end, 10);
    return (*s && !*end && v > 0 && v < 65536) ? (int)v : -1;
}

/* Parse an address with an optional /bits. Returns 1 on success. */
static int parse_addr(const char *s, egress_entry *e) {
    char buf[64];
    if (strlen(s) >= sizeof buf) return 0;
    kai_strlcpy(buf, s, sizeof buf);
    char *slash = strchr(buf, '/');
    if (slash) *slash = '\0';
    if (inet_pton(AF_INET, buf, e->addr) == 1) e->family = AF_INET, e->bits = 32;
    else if (inet_pton(AF_INET6, buf, e->addr) == 1) e->family = AF_INET6, e->bits = 128;
    else return 0;
    if (slash) {
        char *end;
        long b = strtol(slash + 1, &end, 10);
        if (!slash[1] || *end || b < 0 || b > e->bits) return 0;
        e->bits = (int)b;
    }
    return 1;
}

static int valid_hostname(const char *s) {
    if (!*s || strlen(s) > 253) return 0;
    for (const char *c = s; *c; c++)
        if (!isalnum((unsigned char)*c) && *c != '-' && *c != '.' && *c != '_') return 0;
    return 1;
}

static int parse_entry(const char *s, egress_entry *e) {
    memset(e, 0, sizeof *e);
    char buf[300];
    if (!s || !*s || strlen(s) >= sizeof buf) return 0;
    kai_strlcpy(buf, s, sizeof buf);
    char *port = NULL;
    if (buf[0] == '[') { /* [v6] or [v6/bits], then an optional :port */
        char *close = strchr(buf, ']');
        if (!close) return 0;
        *close = '\0';
        if (close[1] == ':') port = close + 2;
        else if (close[1]) return 0;
        if (!parse_addr(buf + 1, e) || e->family != AF_INET6) return 0;
    } else {
        char *colon = strchr(buf, ':');
        if (colon && strchr(colon + 1, ':')) { /* bare IPv6: no port possible */
            if (!parse_addr(buf, e) || e->family != AF_INET6) return 0;
        } else {
            if (colon) *colon = '\0', port = colon + 1;
            if (parse_addr(buf, e)) {
                if (e->family != AF_INET) return 0;
            } else if (!strchr(buf, '/') && valid_hostname(buf)) {
                kai_strlcpy(e->host, buf, sizeof e->host);
            } else {
                return 0;
            }
        }
    }
    if (port && (e->port = parse_port(port)) < 0) return 0;
    return 1;
}

int kai_egress_entry_valid(const char *entry) {
    egress_entry e;
    return parse_entry(entry, &e);
}

static int prefix_match(const unsigned char *a, const unsigned char *b, int bits) {
    int full = bits / 8, rest = bits % 8;
    if (memcmp(a, b, (size_t)full) != 0) return 0;
    if (!rest) return 1;
    unsigned char mask = (unsigned char)(0xff << (8 - rest));
    return (a[full] & mask) == (b[full] & mask);
}

/* ip is the flow's address as the network extension prints it: dotted IPv4,
 * or IPv6 with or without brackets. Fills addr/family; 0 if unreadable. */
static int read_ip(const char *ip, unsigned char *addr, int *family) {
    char buf[64];
    if (!ip) return 0;
    if (ip[0] == '[') ip++;
    if (strlen(ip) >= sizeof buf) return 0;
    kai_strlcpy(buf, ip, sizeof buf);
    char *close = strchr(buf, ']');
    if (close) *close = '\0';
    char *zone = strchr(buf, '%'); /* fe80::1%en0 */
    if (zone) *zone = '\0';
    if (inet_pton(AF_INET, buf, addr) == 1) { *family = AF_INET; return 1; }
    if (inet_pton(AF_INET6, buf, addr) == 1) {
        static const unsigned char v4mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
        if (memcmp(addr, v4mapped, 12) == 0) { /* ::ffff:1.2.3.4 is IPv4 */
            memmove(addr, addr + 12, 4);
            *family = AF_INET;
        } else {
            *family = AF_INET6;
        }
        return 1;
    }
    return 0;
}

static int is_loopback(const unsigned char *addr, int family) {
    static const unsigned char v6lo[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    return family == AF_INET ? addr[0] == 127 : memcmp(addr, v6lo, 16) == 0;
}

int kai_egress_endpoint_allowed(const kai_policy *p, const char *host, const char *ip, int port,
                                char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p) return 0;
    unsigned char addr[16];
    int family = 0, have_ip = read_ip(ip, addr, &family);
    if (have_ip && is_loopback(addr, family)) {
        if (why) kai_strlcpy(why, "this Mac (loopback)", whylen);
        return 1;
    }
    for (int i = 0; i < p->negress; i++) {
        egress_entry e;
        if (!parse_entry(p->egress_allow[i], &e)) continue;
        if (e.port && e.port != port) continue;
        int hit = e.host[0] ? (host && *host && host_covered(host, e.host))
                            : (have_ip && e.family == family && prefix_match(addr, e.addr, e.bits));
        if (hit) {
            if (why) kai_strlcpy(why, p->egress_allow[i], whylen);
            return 1;
        }
    }
    return 0;
}

int kai_egress_allowed(const kai_policy *p, const char *host, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !host || !*host) return 0;
    for (int i = 0; i < p->negress; i++) {
        egress_entry e;
        /* any-port host entries only: a port or address entry needs the
         * connection's details (kai_egress_endpoint_allowed) */
        if (!parse_entry(p->egress_allow[i], &e) || !e.host[0] || e.port) continue;
        if (host_covered(host, e.host)) {
            if (why) kai_strlcpy(why, p->egress_allow[i], whylen);
            return 1;
        }
    }
    return 0;
}

/* ---- TLS ClientHello -> SNI ---- */

typedef struct {
    const unsigned char *p;
    size_t len, off;
} rd_t;

static int rd_u8(rd_t *r, unsigned *v) {
    if (r->off + 1 > r->len) return 0;
    *v = r->p[r->off++];
    return 1;
}
static int rd_u16(rd_t *r, unsigned *v) {
    if (r->off + 2 > r->len) return 0;
    *v = ((unsigned)r->p[r->off] << 8) | r->p[r->off + 1];
    r->off += 2;
    return 1;
}
static int rd_u24(rd_t *r, unsigned *v) {
    if (r->off + 3 > r->len) return 0;
    *v = ((unsigned)r->p[r->off] << 16) | ((unsigned)r->p[r->off + 1] << 8) | r->p[r->off + 2];
    r->off += 3;
    return 1;
}
static int rd_skip(rd_t *r, size_t n) {
    if (n > r->len - r->off) return 0;
    r->off += n;
    return 1;
}

/* A hostname we are willing to return: letters, digits, '-', '.', '_'. */
static int sane_host(const unsigned char *h, size_t n) {
    if (!n || n > 253) return 0;
    for (size_t i = 0; i < n; i++)
        if (!(isalnum(h[i]) || h[i] == '-' || h[i] == '.' || h[i] == '_')) return 0;
    return 1;
}

int kai_tls_sni(const unsigned char *buf, size_t len, char *host, size_t hostlen) {
    if (host && hostlen) host[0] = '\0';
    if (!buf) return 0;
    /* TLS record header: type 22 (handshake), version 3.x, length */
    if (len < 5) return (len == 0 || buf[0] == 22) ? -1 : 0;
    if (buf[0] != 22 || buf[1] != 3) return 0;
    size_t reclen = ((size_t)buf[3] << 8) | buf[4];
    if (reclen < 4) return 0;
    if (len < 5 + reclen) {
        /* A ClientHello almost always fits one record; wait for all of it. */
        return -1;
    }
    rd_t r = {buf + 5, reclen, 0};
    unsigned htype, hlen;
    if (!rd_u8(&r, &htype) || htype != 1) return 0; /* ClientHello */
    if (!rd_u24(&r, &hlen)) return 0;
    if (hlen > r.len - r.off) return 0; /* fragmented across records: give up */
    r.len = r.off + hlen;

    unsigned v, n;
    if (!rd_skip(&r, 2 + 32)) return 0;                 /* version, random */
    if (!rd_u8(&r, &n) || !rd_skip(&r, n)) return 0;    /* session id */
    if (!rd_u16(&r, &n) || !rd_skip(&r, n)) return 0;   /* cipher suites */
    if (!rd_u8(&r, &n) || !rd_skip(&r, n)) return 0;    /* compression */
    if (r.off == r.len) return 0;                       /* no extensions */
    unsigned extlen;
    if (!rd_u16(&r, &extlen) || extlen > r.len - r.off) return 0;
    size_t extend = r.off + extlen;

    while (r.off + 4 <= extend) {
        unsigned etype, elen;
        rd_u16(&r, &etype);
        rd_u16(&r, &elen);
        if (elen > extend - r.off) return 0;
        if (etype != 0) { r.off += elen; continue; } /* 0 = server_name */
        rd_t e = {r.p + r.off, elen, 0};
        unsigned listlen;
        if (!rd_u16(&e, &listlen) || listlen > e.len - e.off) return 0;
        size_t listend = e.off + listlen;
        while (e.off + 3 <= listend) {
            unsigned ntype, nlen;
            rd_u8(&e, &ntype);
            rd_u16(&e, &nlen);
            if (nlen > listend - e.off) return 0;
            if (ntype == 0) { /* host_name */
                const unsigned char *h = e.p + e.off;
                if (!sane_host(h, nlen) || !host || nlen + 1 > hostlen) return 0;
                for (unsigned i = 0; i < nlen; i++) host[i] = (char)tolower(h[i]);
                host[nlen] = '\0';
                return 1;
            }
            e.off += nlen;
        }
        return 0;
    }
    (void)v;
    return 0;
}
