/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * Network wall helpers: the egress allowlist and a TLS ClientHello parser
 * that finds the server name (SNI). The network extension sees most flows as
 * a bare IP address, so the hostname comes from the first bytes the client
 * sends. Everything here runs on untrusted input: every read is bounds-checked.
 */
#include "internal.h"

#include <ctype.h>
#include <string.h>

/* host == entry, or host ends with "." + entry. Case-insensitive. */
static int host_covered(const char *host, const char *entry) {
    size_t hl = strlen(host), el = strlen(entry);
    while (hl && host[hl - 1] == '.') hl--; /* "example.com." is a valid FQDN */
    if (!el || el > hl) return 0;
    if (strncasecmp(host + hl - el, entry, el) != 0) return 0;
    return hl == el || host[hl - el - 1] == '.';
}

int kai_egress_allowed(const kai_policy *p, const char *host, char *why, size_t whylen) {
    if (why && whylen) why[0] = '\0';
    if (!p || !host || !*host) return 0;
    for (int i = 0; i < p->negress; i++) {
        if (host_covered(host, p->egress_allow[i])) {
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
