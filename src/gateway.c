/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * kai gateway: a local AI gateway. Agents send their model API requests here
 * instead of straight to the provider:
 *
 *   ANTHROPIC_BASE_URL=http://127.0.0.1:8787            Claude Code, Anthropic SDKs
 *   OPENAI_BASE_URL=http://127.0.0.1:8787/openai/v1     Codex, OpenAI SDKs
 *   base URL http://127.0.0.1:8787/openrouter/api/v1    OpenRouter clients
 *
 * Every string in the JSON request body goes through the policy (redact
 * secrets, replace codenames, block on confidential markers) before the
 * request is forwarded over HTTPS with the caller's own credentials. The
 * response streams back untouched, so server-sent events keep working.
 *
 * Listens on loopback only. It is not an open proxy: upstreams are fixed.
 */
#include "cJSON.h"
#include "internal.h"

#include <curl/curl.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_HEAD (64 * 1024)
#define MAX_BODY (32 * 1024 * 1024)

/* ---------- upstreams ---------- */

typedef struct {
    const char *prefix; /* path prefix on the gateway, stripped before forwarding */
    const char *env;    /* override, used by tests */
    const char *url;
    const char *name;
    int openai_errors;  /* error body shape */
} upstream_t;

static const upstream_t UPSTREAMS[] = {
    {"/openai/", "KAI_GATEWAY_OPENAI", "https://api.openai.com", "openai", 1},
    {"/openrouter/", "KAI_GATEWAY_OPENROUTER", "https://openrouter.ai", "openrouter", 1},
    {"/", "KAI_GATEWAY_ANTHROPIC", "https://api.anthropic.com", "anthropic", 0},
};

static const upstream_t *route(const char *target, const char **rest) {
    for (size_t i = 0; i < sizeof UPSTREAMS / sizeof UPSTREAMS[0]; i++) {
        size_t n = strlen(UPSTREAMS[i].prefix);
        if (strncmp(target, UPSTREAMS[i].prefix, n) == 0) {
            *rest = target + n - 1; /* keep the leading '/' */
            return &UPSTREAMS[i];
        }
    }
    *rest = target;
    return &UPSTREAMS[sizeof UPSTREAMS / sizeof UPSTREAMS[0] - 1];
}

static const char *upstream_base(const upstream_t *u) {
#ifdef KAI_TEST_DIRECT_POLICY
    /* Test builds only: the TLS-validation suite points an upstream at a local
     * bad-cert server through this env var. It is never compiled into product,
     * so a shipped gateway's upstreams are exactly the fixed https list above -
     * neither the policy nor the environment can redirect them. */
    const char *e = getenv(u->env);
    if (e && *e) return e;
#else
    (void)u->env;
#endif
    return u->url;
}

/* ---------- socket helpers ---------- */

static int send_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
#ifdef MSG_NOSIGNAL
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
#else
        ssize_t w = send(fd, p, n, 0);
#endif
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static const char *reason_phrase(long code) {
    switch (code) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 413: return "Payload Too Large";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 529: return "Overloaded";
    default: return "Status";
    }
}

static void respond_json(int fd, int code, const char *body) {
    char head[256];
    int n = snprintf(head, sizeof head,
                     "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                     "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                     code, reason_phrase(code), strlen(body));
    send_all(fd, head, (size_t)n);
    send_all(fd, body, strlen(body));
}

/* An error in the shape the caller's SDK understands. */
static void respond_error(int fd, int code, const upstream_t *u, const char *msg) {
    cJSON *o = cJSON_CreateObject();
    if (u && u->openai_errors) {
        cJSON *e = cJSON_AddObjectToObject(o, "error");
        cJSON_AddStringToObject(e, "message", msg);
        cJSON_AddStringToObject(e, "type", "kai_blocked");
    } else {
        cJSON_AddStringToObject(o, "type", "error");
        cJSON *e = cJSON_AddObjectToObject(o, "error");
        cJSON_AddStringToObject(e, "type", code == 403 ? "permission_error" : "api_error");
        cJSON_AddStringToObject(e, "message", msg);
    }
    char *s = cJSON_PrintUnformatted(o);
    respond_json(fd, code, s ? s : "{}");
    free(s);
    cJSON_Delete(o);
}

/* ---------- request parsing ---------- */

typedef struct {
    char method[16];
    char *target;
    char **hdr; /* "Name: value" */
    int nhdr;
    char *body;
    size_t bodylen;
} request_t;

static void request_free(request_t *r) {
    free(r->target);
    for (int i = 0; i < r->nhdr; i++) free(r->hdr[i]);
    free(r->hdr);
    free(r->body);
}

static const char *header(const request_t *r, const char *name) {
    size_t n = strlen(name);
    for (int i = 0; i < r->nhdr; i++)
        if (strncasecmp(r->hdr[i], name, n) == 0 && r->hdr[i][n] == ':') {
            const char *v = r->hdr[i] + n + 1;
            while (*v == ' ' || *v == '\t') v++;
            return v;
        }
    return NULL;
}

/* Read more bytes into buf (growing), returns bytes read, 0 on EOF, -1 error. */
static ssize_t read_more(int fd, sb_t *buf) {
    char tmp[16384];
    ssize_t n;
    do { n = recv(fd, tmp, sizeof tmp, 0); } while (n < 0 && errno == EINTR);
    if (n > 0) sb_add(buf, tmp, (size_t)n);
    return n;
}

/* Decode a chunked body in place. Returns decoded length or -1 if incomplete. */
static long dechunk(const char *in, size_t len, sb_t *out) {
    size_t i = 0;
    for (;;) {
        const char *nl = memchr(in + i, '\n', len - i);
        if (!nl) return -1;
        unsigned long sz = strtoul(in + i, NULL, 16);
        i = (size_t)(nl - in) + 1;
        if (sz == 0) return (long)out->len;
        if (sz > MAX_BODY || len - i < sz + 2) return -1;
        sb_add(out, in + i, sz);
        i += sz + 2;
    }
}

/* 0 ok, -1 closed / malformed, -2 too large */
static int read_request(int fd, request_t *r) {
    memset(r, 0, sizeof *r);
    sb_t buf;
    sb_init(&buf);
    char *end = NULL;
    while (!(end = buf.p ? strstr(buf.p, "\r\n\r\n") : NULL)) {
        if (buf.len > MAX_HEAD) { sb_free(&buf); return -2; }
        if (read_more(fd, &buf) <= 0) { sb_free(&buf); return -1; }
    }
    size_t headlen = (size_t)(end - buf.p) + 4;

    /* request line */
    char *line_end = strstr(buf.p, "\r\n");
    char target[8192];
    if (sscanf(buf.p, "%15s %8191s", r->method, target) != 2) { sb_free(&buf); return -1; }
    r->target = strdup(target);
    /* headers */
    for (char *h = line_end + 2; h < end;) {
        char *e = strstr(h, "\r\n");
        if (!e || e > end) e = end;
        size_t n = (size_t)(e - h);
        char **nh = realloc(r->hdr, (size_t)(r->nhdr + 1) * sizeof *nh);
        if (!nh) break;
        r->hdr = nh;
        r->hdr[r->nhdr] = malloc(n + 1);
        if (!r->hdr[r->nhdr]) break;
        memcpy(r->hdr[r->nhdr], h, n);
        r->hdr[r->nhdr++][n] = '\0';
        h = e + 2;
    }

    /* body */
    const char *cl = header(r, "Content-Length");
    const char *te = header(r, "Transfer-Encoding");
    size_t have = buf.len - headlen;
    if (te && strncasecmp(te, "chunked", 7) == 0) {
        sb_t out;
        for (;;) {
            sb_init(&out);
            if (dechunk(buf.p + headlen, buf.len - headlen, &out) >= 0) break;
            sb_free(&out);
            if (buf.len - headlen > MAX_BODY) { sb_free(&buf); return -2; }
            if (read_more(fd, &buf) <= 0) { sb_free(&buf); return -1; }
        }
        r->bodylen = out.len;
        r->body = sb_take(&out);
    } else if (cl) {
        unsigned long want = strtoul(cl, NULL, 10);
        if (want > MAX_BODY) { sb_free(&buf); return -2; }
        while (have < want) {
            if (read_more(fd, &buf) <= 0) { sb_free(&buf); return -1; }
            have = buf.len - headlen;
        }
        r->body = malloc(want + 1);
        if (!r->body) { sb_free(&buf); return -1; }
        memcpy(r->body, buf.p + headlen, want);
        r->body[want] = '\0';
        r->bodylen = want;
    }
    sb_free(&buf);
    return 0;
}

/* ---------- cleaning ---------- */

static void merge(kai_report *into, const kai_report *from) {
    for (int i = 0; i < from->nhits; i++) {
        int found = 0;
        for (int j = 0; j < into->nhits && !found; j++)
            if (strcmp(into->hits[j].rule, from->hits[i].rule) == 0) {
                into->hits[j].count += from->hits[i].count;
                found = 1;
            }
        if (!found && into->nhits < KAI_MAX_HITS) into->hits[into->nhits++] = from->hits[i];
    }
    if (from->worst > into->worst) into->worst = from->worst;
    into->skipped |= from->skipped;
}

/* Is this object an image/document source whose "data" is base64? */
static int is_binary_source(const cJSON *obj) {
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(obj, "type");
    return cJSON_IsString(t) && strcmp(t->valuestring, "base64") == 0;
}

static void clean_json(const kai_policy *p, cJSON *node, kai_report *rep, int depth) {
    if (!node || depth > 64) return;
    for (cJSON *c = node->child; c; c = c->next) {
        if (cJSON_IsString(c) && c->valuestring) {
            if (c->string && strcmp(c->string, "data") == 0 && is_binary_source(node)) continue;
            kai_report one;
            char *clean = kai_scan_text(p, c->valuestring, &one);
            if (clean && strcmp(clean, c->valuestring) != 0) {
                char *old = c->valuestring;
                c->valuestring = clean; /* cJSON frees it with the tree */
                free(old);
            } else {
                free(clean);
            }
            merge(rep, &one);
        } else if (cJSON_IsObject(c) || cJSON_IsArray(c)) {
            clean_json(p, c, rep, depth + 1);
        }
    }
}

/* ---------- forwarding ---------- */

typedef struct {
    int fd;
    CURL *curl;
    int head_sent;
    int client_gone;
    sb_t head; /* response headers being collected */
} fwd_t;

static int hop_by_hop(const char *h) {
    static const char *const drop[] = {"host:", "content-length:", "connection:",
                                       "keep-alive:", "transfer-encoding:", "te:",
                                       "trailer:", "upgrade:", "proxy-", "accept-encoding:",
                                       "expect:"};
    for (size_t i = 0; i < sizeof drop / sizeof drop[0]; i++)
        if (strncasecmp(h, drop[i], strlen(drop[i])) == 0) return 1;
    return 0;
}

static void send_head(fwd_t *f) {
    if (f->head_sent) return;
    long code = 0;
    curl_easy_getinfo(f->curl, CURLINFO_RESPONSE_CODE, &code);
    char line[64];
    int n = snprintf(line, sizeof line, "HTTP/1.1 %ld %s\r\n", code, reason_phrase(code));
    send_all(f->fd, line, (size_t)n);
    if (f->head.p) send_all(f->fd, f->head.p, f->head.len);
    send_all(f->fd, "Connection: close\r\n\r\n", 21);
    f->head_sent = 1;
}

static size_t on_header(char *buf, size_t size, size_t n, void *ud) {
    fwd_t *f = ud;
    size_t len = size * n;
    if (len >= 5 && strncmp(buf, "HTTP/", 5) == 0) { /* new status line: reset */
        sb_free(&f->head);
        sb_init(&f->head);
        return len;
    }
    if (len <= 2) { /* blank line: end of this header block */
        long code = 0;
        curl_easy_getinfo(f->curl, CURLINFO_RESPONSE_CODE, &code);
        if (code >= 200) send_head(f);
        return len;
    }
    if (!hop_by_hop(buf)) sb_add(&f->head, buf, len);
    return len;
}

static size_t on_body(char *buf, size_t size, size_t n, void *ud) {
    fwd_t *f = ud;
    send_head(f);
    if (send_all(f->fd, buf, size * n) != 0) {
        f->client_gone = 1;
        return 0; /* abort the transfer */
    }
    return size * n;
}

static void forward(int fd, const request_t *r, const upstream_t *u, const char *path,
                    const char *body, size_t bodylen) {
    char url[8400];
    snprintf(url, sizeof url, "%s%s", upstream_base(u), path);
    CURL *c = curl_easy_init();
    if (!c) { respond_error(fd, 502, u, "Kai gateway: cannot start upstream request"); return; }
    struct curl_slist *hs = NULL;
    for (int i = 0; i < r->nhdr; i++)
        if (!hop_by_hop(r->hdr[i])) hs = curl_slist_append(hs, r->hdr[i]);
    hs = curl_slist_append(hs, "Expect:");

    fwd_t f = {fd, c, 0, 0, {0}};
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, r->method);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, hs);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(c, CURLOPT_TCP_KEEPALIVE, 1L);
    /* Kai is a TLS client here. Enforce full certificate + hostname validation
     * explicitly (defense in depth over the libcurl defaults), require TLS 1.2
     * or newer, and refuse any scheme but HTTPS - including on a redirect - so a
     * downgrade or a stray http:// upstream can never carry model traffic in the
     * clear. No "insecure" path and no custom trust override exists. */
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(c, CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
#ifndef KAI_TEST_DIRECT_POLICY
    /* Product: the fixed upstream list is all https, so refuse any other scheme
     * outright (including on a redirect). Test builds skip only this clause so
     * the fake-upstream streaming suite can use a local http server; the cert,
     * hostname and TLS-version checks above still apply to every https call,
     * which is what the TLS-validation tests exercise. */
#  if defined(CURL_AT_LEAST_VERSION) && CURL_AT_LEAST_VERSION(7, 85, 0)
    curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS_STR, "https");
#  else
    curl_easy_setopt(c, CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
    curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
#  endif
#endif
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, on_header);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &f);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &f);
    if (strcmp(r->method, "GET") != 0 && strcmp(r->method, "HEAD") != 0) {
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body ? body : "");
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)bodylen);
    } else if (strcmp(r->method, "HEAD") == 0) {
        curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
    }
    CURLcode rc = curl_easy_perform(c);
    if (rc != CURLE_OK && !f.head_sent && !f.client_gone) {
        char msg[300];
        snprintf(msg, sizeof msg, "Kai gateway: upstream %s failed: %s", u->name,
                 curl_easy_strerror(rc));
        /* Fail closed and surface it in Activity. A TLS validation failure
         * (CURLE_PEER_FAILED_VERIFICATION / CURLE_SSL_*) lands here. */
        kai_audit("gateway", u->name, "block", "upstream", curl_easy_strerror(rc));
        respond_error(fd, 502, u, msg);
    } else if (!f.head_sent && !f.client_gone) {
        send_head(&f); /* empty body */
    }
    sb_free(&f.head);
    curl_slist_free_all(hs);
    curl_easy_cleanup(c);
}

/* ---------- connection ---------- */

static void handle(int fd) {
    request_t r;
    int rc = read_request(fd, &r);
    if (rc == -2) {
        respond_error(fd, 413, NULL, "Kai gateway: request too large");
        request_free(&r);
        return;
    }
    if (rc != 0) { request_free(&r); return; }

    if (strcmp(r.target, "/_kai/health") == 0) {
        respond_json(fd, 200, "{\"ok\":true,\"service\":\"kai-gateway\"}");
        request_free(&r);
        return;
    }

    const char *path;
    const upstream_t *u = route(r.target, &path);

    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) {
        char msg[320];
        snprintf(msg, sizeof msg, "Kai policy error, failing closed: %s", err);
        respond_error(fd, 503, u, msg);
        request_free(&r);
        return;
    }

    kai_report rep;
    memset(&rep, 0, sizeof rep);
    char *out = NULL;
    size_t outlen = r.bodylen;
    if (r.bodylen) {
        cJSON *root = cJSON_ParseWithLength(r.body, r.bodylen);
        if (root) {
            clean_json(p, root, &rep, 0);
            if (rep.nhits) {
                out = cJSON_PrintUnformatted(root);
                outlen = out ? strlen(out) : 0;
            }
            cJSON_Delete(root);
        } else {
            /* not JSON: clean it as plain text */
            out = kai_scan_text(p, r.body, &rep);
            outlen = out ? strlen(out) : 0;
        }
    }

    char summary[1024] = "";
    if (rep.nhits) kai_report_summary(&rep, summary, sizeof summary);
    if (rep.worst >= KAI_ACT_BLOCK) {
        char msg[1200];
        snprintf(msg, sizeof msg, "Blocked by Kai: request contains blocked content (%s)", summary);
        respond_error(fd, 403, u, msg);
        kai_audit("gateway", u->name, "block", "request", summary);
    } else {
        if (rep.nhits)
            kai_audit("gateway", u->name, kai_action_name(rep.worst), "request", summary);
        forward(fd, &r, u, path, out ? out : r.body, out ? outlen : r.bodylen);
    }
    free(out);
    kai_policy_free(p);
    request_free(&r);
}

static void *conn_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    handle(fd);
    shutdown(fd, SHUT_WR);
    close(fd);
    return NULL;
}

int kai_gateway_run(const char *listen_addr, int port) {
    signal(SIGPIPE, SIG_IGN);
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != 0) {
        fprintf(stderr, "kai gateway: cannot initialise libcurl\n");
        return 1;
    }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("kai gateway: socket"); return 1; }
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, listen_addr, &a.sin_addr) != 1) {
        fprintf(stderr, "kai gateway: bad address %s\n", listen_addr);
        close(s);
        return 1;
    }
    if (!(ntohl(a.sin_addr.s_addr) >> 24 == 127)) {
        fprintf(stderr, "kai gateway: refusing to listen on non-loopback %s\n", listen_addr);
        close(s);
        return 1;
    }
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 64) != 0) {
        fprintf(stderr, "kai gateway: cannot listen on %s:%d: %s\n", listen_addr, port,
                strerror(errno));
        close(s);
        return 1;
    }
    /* Resolve the lazily-initialised paths once, before any threads exist. */
    (void)kai_home();
    (void)kai_policy_file();
    (void)kai_audit_path();
    fprintf(stderr, "kai gateway: listening on http://%s:%d\n", listen_addr, port);
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            perror("kai gateway: accept");
            break;
        }
#ifdef SO_NOSIGPIPE
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        pthread_t t;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &at, conn_thread, (void *)(intptr_t)c) != 0) close(c);
        pthread_attr_destroy(&at);
    }
    close(s);
    curl_global_cleanup();
    return 1;
}
