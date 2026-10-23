// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Scoped Approvals (M3) — the native approval workflow.
//
// SECURITY MODEL: a grant is only enforceable if its HMAC verifies under the
// approval key. That key is generated and held HERE, in the app, and a grant is
// signed ONLY in `approve(...)`, which runs ONLY from a real button click in a
// Kai-owned window. There is deliberately NO CLI/IPC/file trigger that signs a
// grant, so an AI agent — which also cannot read the control-path-protected key
// while the storage wall is on — has no way to turn approval into a bypass.
// Every field shown and signed is Kai-verified (from the extension's pending
// record); an agent-supplied process name is never trusted as identity.
import Foundation
import Security
import SwiftUI
import KaiCore

/// The approval key: 32 random bytes at ~/.kai/approval.key (0600), created on
/// first use. Both the app (to sign) and the storage extension (to verify) read
/// it; the storage wall keeps it out of an agent's reach.
enum KaiApprovalKey {
    static var path: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.kai/approval.key"
    }
    static func ensure() -> Data? {
        if let d = FileManager.default.contents(atPath: path), !d.isEmpty { return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return data
    }
}

/// A pending access request staged by the storage extension. Only Kai-verified
/// fields; `agent` is Kai's classification, not an agent-supplied string.
struct PendingRequest: Decodable, Identifiable {
    let id: String
    let agent: String
    let pid: Int
    let pidversion: UInt64
    let strength: Int
    let resource: String
    let op: String
    let ts: Int
    var strengthLabel: String { strength >= 2 ? "strong" : strength == 1 ? "medium" : "weak" }
}

/// An active grant, decoded from its stored JSON for display/revocation.
struct ActiveGrant: Decodable, Identifiable {
    let id: String
    let agent: String
    let resource: String
    let op: Int
    let scope: Int
    let expires_utc: String
    let hmac: String
    var opLabel: String { op == 1 ? "write" : op == 2 ? "connect" : "read" }
    var scopeLabel: String { scope == 1 ? "once" : "this process" }
    var signed: Bool { !hmac.isEmpty }
    var expiresEpoch: Int { Int(expires_utc) ?? 0 }
}

enum GrantScope { case once, process }

final class GrantManager: ObservableObject {
    @Published private(set) var pending: [PendingRequest] = []
    @Published private(set) var grants: [ActiveGrant] = []

    private var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    private var pendingDir: String { home + "/.kai/pending" }
    private var grantsDir: String { home + "/.kai/grants" }
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        pending = loadJSON(dir: pendingDir).compactMap { try? JSONDecoder().decode(PendingRequest.self, from: $0) }
            .sorted { $0.ts < $1.ts }
        grants = loadJSON(dir: grantsDir).compactMap { try? JSONDecoder().decode(ActiveGrant.self, from: $0) }
            .sorted { $0.id < $1.id }
    }

    private func loadJSON(dir: String) -> [Data] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { FileManager.default.contents(atPath: dir + "/" + $0) }
    }

    /// Sign and persist a grant for a pending request. The ONLY path that signs.
    func approve(_ req: PendingRequest, scope: GrantScope) {
        guard let key = KaiApprovalKey.ensure() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let ttl = (scope == .once) ? 120 : 900           // one-shot 2 min, process 15 min
        let expires = now + ttl
        let gid = UUID().uuidString
        let opCode: Int32 = req.op == "connect" ? 2 :
                            (req.op == "open" || req.op == "readdir") ? 0 : 1
        let scopeCode: Int32 = (scope == .once) ? 1 : 0

        let json: String? = key.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // v2 grant. session_id/project are empty ("any") until M1.2 supplies
            // the verified session; dest_kind is path for storage ops.
            let destKind: Int32 = (req.op == "connect") ? 1 : 0
            guard let c = kai_grant_build_json2(gid, Int64(now), Int64(expires), Int32(req.pid),
                                                req.pidversion, req.agent, Int32(req.strength),
                                                req.resource, opCode, scopeCode, "console-user",
                                                "", "", destKind, base, key.count) else { return nil }
            defer { free(c) }
            return String(cString: c)
        }
        guard let json else { return }
        try? FileManager.default.createDirectory(atPath: grantsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fp = grantsDir + "/" + gid + ".json"
        if FileManager.default.createFile(atPath: fp, contents: Data(json.utf8),
                                          attributes: [.posixPermissions: 0o600]) {
            kai_grant_audit("approved", gid, req.agent, req.resource, opCode,
                            "sign", "approved by console user")
            clearPending(req)
        }
        refresh()
    }

    func deny(_ req: PendingRequest) {
        let opCode: Int32 = req.op == "connect" ? 2 :
                            (req.op == "open" || req.op == "readdir") ? 0 : 1
        kai_grant_audit("denied", req.id, req.agent, req.resource, opCode, "deny", "denied by user")
        clearPending(req); refresh()
    }

    func revoke(_ grant: ActiveGrant) {
        kai_grant_audit("revoked", grant.id, grant.agent, grant.resource, Int32(grant.op),
                        "revoke", "revoked by user")
        try? FileManager.default.removeItem(atPath: grantsDir + "/" + grant.id + ".json")
        refresh()
    }

    private func clearPending(_ req: PendingRequest) {
        try? FileManager.default.removeItem(atPath: pendingDir + "/" + req.id + ".json")
    }
}

// MARK: - Views

/// A single access-request card. Shows only Kai-verified fields; the human
/// chooses Deny / Allow once / Allow this process.
struct ApprovalCard: View {
    let req: PendingRequest
    @ObservedObject var manager: GrantManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KAI — Access Request").font(.headline)
            Text(req.op == "connect"
                 ? "\(req.agent) wants to connect to this destination"
                 : "\(req.agent) wants to \(req.op.uppercased()) a protected file")
            Text(req.resource).font(.system(.caption, design: .monospaced)).lineLimit(2)
            Text("Verified: \(req.agent) · pid \(req.pid) · identity \(req.strengthLabel)")
                .font(.caption).foregroundColor(.secondary)
            if req.op != "connect" {
                Text("Allowing file access does not change the network wall.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            HStack {
                Button("Deny") { manager.deny(req) }
                Button("Allow once") { manager.approve(req, scope: .once) }
                Button("Allow this process (15 min)") { manager.approve(req, scope: .process) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// The approvals section for the menu: pending requests + active grants.
struct ApprovalsSection: View {
    @ObservedObject var manager: GrantManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !manager.pending.isEmpty {
                Text("Pending approvals").font(.caption).foregroundColor(.secondary)
                ForEach(manager.pending) { ApprovalCard(req: $0, manager: manager) }
            }
            if !manager.grants.isEmpty {
                Text("Active grants").font(.caption).foregroundColor(.secondary)
                ForEach(manager.grants) { g in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(g.agent) · \(g.opLabel) · \(g.scopeLabel)\(g.signed ? "" : " (unsigned)")")
                                .font(.caption)
                            Text(g.resource).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                        }
                        Spacer()
                        Button("Revoke") { manager.revoke(g) }
                    }
                }
            }
        }
    }
}
