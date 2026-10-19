// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Endpoint Security client for the storage wall. NOT in the Xcode build yet:
// it needs Apple's com.apple.developer.endpoint-security.client entitlement,
// which Apple grants per-team on request. Until then, building this would
// fail to sign, so it is left out of app/macos/project.yml. When the
// entitlement arrives, add a `system-extension` target for it (see
// docs/WALLS.md) and this file compiles as-is.
//
// It does nothing but gather the three facts the decision needs — is the
// opening process an agent, is it a write, and the real path — and hand them
// to the C engine kai_storage_open_allowed (src/storage.c), which is already
// tested. The policy lives with the user; the client runs as root and reads
// it the same way the network extension does.
#if KAI_ENDPOINT_SECURITY
import EndpointSecurity
import Foundation

final class StorageProvider {
    private var client: OpaquePointer?
    private let policyHome: String
    private var policy: OpaquePointer?   // kai_policy*

    init(policyHome: String) {
        self.policyHome = policyHome
    }

    func start() throws {
        reloadPolicy()
        var c: OpaquePointer?
        let res = es_new_client(&c) { [weak self] _, msg in
            self?.handle(msg)
        }
        guard res == ES_NEW_CLIENT_RESULT_SUCCESS, let c else {
            throw NSError(domain: "kai.storage", code: Int(res.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "es_new_client failed (\(res))"])
        }
        client = c
        // Wake only for AUTH_OPEN; mute nothing yet (path muting is an
        // optimisation, added once prefixes are wired from the policy).
        var events = [ES_EVENT_TYPE_AUTH_OPEN]
        es_subscribe(c, &events, UInt32(events.count))
    }

    private func reloadPolicy() {
        if let p = policy { kai_policy_free(p); policy = nil }
        policy = kai_policy_load(nil, nil, 0)
    }

    private func handle(_ msg: UnsafePointer<es_message_t>) {
        let m = msg.pointee
        guard m.event_type == ES_EVENT_TYPE_AUTH_OPEN, let client else { return }
        let pid = audit_token_to_pid(m.process.pointee.audit_token)
        let path = String(cString: m.event.open.file.pointee.path.data)

        var name = [CChar](repeating: 0, count: 64)
        let isAgent = kai_process_agent(policy, pid, &name, name.count, nil) == 1
        var why = [CChar](repeating: 0, count: 256)
        let write = (m.event.open.fflag & Int32(FWRITE)) != 0
        let allow = kai_storage_open_allowed(policy, isAgent ? 1 : 0, write ? 1 : 0,
                                             path, &why, why.count) == 1

        // AUTH_OPEN answers with the flags the process may keep. Deny = 0.
        let authorized: UInt32 = allow ? UInt32(bitPattern: -1) : 0
        es_respond_flags_result(client, msg, authorized, false)
    }

    deinit {
        if let c = client { es_unsubscribe_all(c); es_delete_client(c) }
        if let p = policy { kai_policy_free(p) }
    }
}
#endif
