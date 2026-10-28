/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
 *
 * The one authenticated control path (v1 Step 3 / M1.3).
 *
 * Policy, grants and pending changes are written by exactly one process: the
 * signed Kai app, which hosts an XPC Mach service. Everyone else - the app's
 * own UI aside - is a CLIENT:
 *
 *   kai_control_request()        the `kai` CLI side: package a write command and
 *                                send it to the service, fail with a clear
 *                                message if the app is not running. It never
 *                                writes the control store itself.
 *   kai_control_service_apply()  the service side (called by the app, in C):
 *                                run the already-validated refuse/pending/apply
 *                                logic, now that the app has verified the
 *                                caller by audit token + code signature + agent
 *                                tree. Runs in the app process, which the
 *                                storage wall lets write the control store.
 *
 * The caller check itself (audit token -> Team ID -> agent tree) lives in the
 * Swift service (app/macos/Sources/KaiBar/ControlService.swift); this file is
 * the transport and the shared decision logic.
 */
#include "internal.h"

/* Build guard (Step 3): the test seam that skips agent-refusal and the pending
 * hold must never reach a shipped build. Product builds define KAI_PRODUCT_BUILD
 * (see the xcodegen yml files); if the seam is also set, fail the compile. */
#if defined(KAI_PRODUCT_BUILD) && defined(KAI_TEST_DIRECT_POLICY)
#error "KAI_TEST_DIRECT_POLICY must never be compiled into a product build"
#endif

#include <string.h>
#include <stdio.h>

/* ---- server side: run the decision logic the app already trusts ---- */

/* Set by the app before each apply so the policy-change audit records the real
 * caller's process tree, not the app's. Read by caller_context() in manage.c. */
void kai_caller_pid_set(int pid);
int  kai_policy_last_was_pending(void);
int  kai_grant_dispatch(int argc, char **argv, int caller_is_agent);

int kai_control_service_apply(const char *op, int argc, char **argv,
                              int caller_pid, int caller_is_agent,
                              char *msg, size_t msglen) {
    if (msg && msglen) msg[0] = '\0';
    if (!op) { if (msg) kai_strlcpy(msg, "bad request", msglen); return 1; }

    /* An MCP call: not a policy/grant write, so it is NOT subject to the
     * agent-refusal (agents legitimately make MCP requests). The service stamps
     * the session from the caller's audit token and only stages a card or honors
     * an existing grant - it never creates a grant here. */
    if (strcmp(op, "mcp") == 0) {
        return kai_mcp_service_request(caller_pid, argc > 0 ? argv[0] : "",
                                       argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : "",
                                       msg, msglen);
    }

    kai_caller_pid_set(caller_pid);
    int rc;
    const char *verb = argc > 0 ? argv[0] : "";
    if (strcmp(op, "policy") == 0) {
        rc = kai_policy_dispatch(argc, argv, caller_is_agent);
    } else if (strcmp(op, "grant") == 0) {
        rc = kai_grant_dispatch(argc, argv, caller_is_agent);
    } else {
        if (msg) kai_strlcpy(msg, "unknown control op", msglen);
        kai_caller_pid_set(0);
        return 1;
    }
    kai_caller_pid_set(0);

    if (msg && msglen) {
        if (rc == 3)
            snprintf(msg, msglen,
                     "Refused: an agent process may request but cannot change Kai's %s.",
                     strcmp(op, "grant") == 0 ? "grants" : "policy");
        else if (rc == 0 && strcmp(op, "policy") == 0 && kai_policy_last_was_pending())
            snprintf(msg, msglen,
                     "Held for your confirmation in Kai (this reduces protection); "
                     "it is NOT active yet.");
        else if (rc == 0)
            snprintf(msg, msglen, "Done: %s %s.", op, verb[0] ? verb : "change");
        else
            snprintf(msg, msglen, "Kai could not apply that %s change (code %d).", op, rc);
    }
    return rc;
}

/* ---- server side transport: the app hosts the Mach service ---- */
#ifndef KAI_TEST_DIRECT_POLICY
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/message.h>
#include <stdlib.h>

/* libxpc SPI: the audit token is the only trustworthy caller identity (a pid
 * can be recycled). Declared here so we don't depend on a private header. */
extern void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *);

static int caller_is_agent_pid(int pid) {
    char err[256];
    kai_policy *p = kai_policy_load(NULL, err, sizeof err);
    if (!p) return 0;               /* can't tell -> don't wrongly refuse a human */
    char name[64]; int apid;
    int hit = kai_process_agent(p, pid, name, sizeof name, &apid);
    kai_policy_free(p);
    return hit;
}

static void control_handle(xpc_connection_t peer, xpc_object_t msg) {
    audit_token_t tok;
    xpc_connection_get_audit_token(peer, &tok);
    char team[32] = "", signid[128] = ""; int pid = -1;
    int valid = kai_audit_token_identity(&tok, sizeof tok, team, sizeof team,
                                         signid, sizeof signid, &pid);
    char outmsg[600] = ""; int rc;
    /* Only a validly-signed process on Kai's Team ID may even be heard. */
    if (!valid || strcmp(team, "KD446VDTM2") != 0) {
        rc = 71;
        kai_strlcpy(outmsg, "Refused: caller is not a verified Kai component.", sizeof outmsg);
    } else {
        const char *op = xpc_dictionary_get_string(msg, "op");
        xpc_object_t arr = xpc_dictionary_get_value(msg, "argv");
        int argc = (arr && xpc_get_type(arr) == XPC_TYPE_ARRAY) ? (int)xpc_array_get_count(arr) : 0;
        char **argv = calloc((size_t)argc + 1, sizeof *argv);
        for (int i = 0; argv && i < argc; i++) {
            const char *s = xpc_array_get_string(arr, (size_t)i);
            argv[i] = strdup(s ? s : "");
        }
        int is_agent = caller_is_agent_pid(pid);
        rc = kai_control_service_apply(op ? op : "", argc, argv ? argv : (char *[]){NULL},
                                       pid, is_agent, outmsg, sizeof outmsg);
        for (int i = 0; argv && i < argc; i++) free(argv[i]);
        free(argv);
    }
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (reply) {
        xpc_dictionary_set_int64(reply, "rc", rc);
        xpc_dictionary_set_string(reply, "message", outmsg);
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
    }
}

/* Start the one control service. Called once by the signed app at launch. The
 * Mach name must be advertised by a launchd agent for the app (see the bundled
 * LaunchAgent / SMAppService registration); the listener checks in here. */
int kai_control_service_start(void) {
    static xpc_connection_t listener = NULL;
    if (listener) return 0;
    dispatch_queue_t q =
        dispatch_queue_create("io.github.sameehj.kai.control", DISPATCH_QUEUE_SERIAL);
    listener = xpc_connection_create_mach_service(KAI_CONTROL_MACH_NAME, q,
                                                  XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return -1;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peerobj) {
        if (xpc_get_type(peerobj) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)peerobj;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
            if (xpc_get_type(m) == XPC_TYPE_DICTIONARY) control_handle(peer, m);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    return 0;
}

/* ---- client side: the CLI asks the app to make the change ---- */

int kai_control_request(const char *op, int argc, char **argv, char *msg, size_t msglen) {
    if (msg && msglen) msg[0] = '\0';
    xpc_connection_t conn =
        xpc_connection_create_mach_service(KAI_CONTROL_MACH_NAME, NULL, 0);
    if (!conn) {
        if (msg) kai_strlcpy(msg, "Kai control service unavailable.", msglen);
        return 70;
    }
    /* A listener-less client still needs an event handler set before resume. */
    xpc_connection_set_event_handler(conn, ^(xpc_object_t e) { (void)e; });
    xpc_connection_resume(conn);

    xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(req, "op", op);
    xpc_object_t arr = xpc_array_create(NULL, 0);
    for (int i = 0; i < argc; i++)
        xpc_array_set_string(arr, XPC_ARRAY_APPEND, argv[i] ? argv[i] : "");
    xpc_dictionary_set_value(req, "argv", arr);

    /* Never hang: if the service doesn't answer in 10 s (launchd can't start
     * it - e.g. an old copy of Kai stole its registration), say so. */
    __block xpc_object_t reply = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(conn, req, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                           ^(xpc_object_t r) { reply = xpc_retain(r); dispatch_semaphore_signal(done); });
    int timed_out = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC)) != 0;
    int rc = 70;
    if (timed_out) {
        if (msg) kai_strlcpy(msg,
                             "Kai's control service didn't answer. Open Kai (the installed app in "
                             "/Applications) - it re-registers the service - then try again.",
                             msglen);
        xpc_connection_cancel(conn);           /* the late reply, if any, is dropped */
        xpc_release(arr); xpc_release(req);
        return rc;
    }
    if (reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        rc = (int)xpc_dictionary_get_int64(reply, "rc");
        const char *m = xpc_dictionary_get_string(reply, "message");
        if (m && msg) kai_strlcpy(msg, m, msglen);
    } else if (msg) {
        /* XPC_TYPE_ERROR: the service isn't registered or the app isn't up. */
        kai_strlcpy(msg,
                    "Kai isn't running. Open the Kai app, then try this change again. "
                    "(Agents can't change Kai's policy or grants - only you can.)",
                    msglen);
    }
    if (reply) xpc_release(reply);
    xpc_release(arr);
    xpc_release(req);
    xpc_connection_cancel(conn);
    xpc_release(conn);
    return rc;
}
#else
/* The test binary (KAI_TEST_DIRECT_POLICY) never reaches the service: its CLI
 * write paths call the dispatchers directly. Provide a stub so the symbol
 * exists if referenced. */
int kai_control_request(const char *op, int argc, char **argv, char *msg, size_t msglen) {
    (void)op; (void)argc; (void)argv;
    if (msg && msglen) kai_strlcpy(msg, "direct (test build)", msglen);
    return 0;
}
int kai_control_service_start(void) { return 0; }
#endif
