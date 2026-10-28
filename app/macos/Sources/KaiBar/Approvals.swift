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
import LocalAuthentication
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
    var note: String? = nil     // plain explanation of the resource class (e.g. trust store)
    var tier: Int? = nil        // kai_override_tier_t: 2 = override, 3 = break-glass, 4 = never
    var session: String? = nil  // the ES session this request belongs to (for "this session" grants)
    var project: String? = nil  // that session's project folder (the card names the session by it)
    var declaredHost: String? = nil  // MCP: the server's .mcp.json host, offered as a second grant
    var strengthLabel: String { strength >= 2 ? "strong" : strength == 1 ? "medium" : "weak" }
    var isMCP: Bool { resource.hasPrefix("mcp:") }
    var opLabel: String { op == "connect" ? "connect" : (op == "open" || op == "readdir") ? "read" : "write" }
    // ---- Phase B item 9: the card in plain words ----

    var agentTitle: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
    /// ` (session "kai")`, from the session's project folder, or "".
    var sessionLabel: String {
        guard let p = project, !p.isEmpty else { return "" }
        return " (session \u{201C}\((p as NSString).lastPathComponent)\u{201D})"
    }
    private var inTemp: Bool {
        resource.contains("/var/folders/") || resource.hasPrefix("/tmp/") || resource.hasPrefix("/private/tmp/")
    }
    var verb: String {
        if isMCP { return "use" }
        switch op {
        case "connect": return "connect to"
        case "open", "readdir": return "read"
        case "unlink": return "delete"
        case "rename": return "move"
        default: return "change"
        }
    }
    /// What was touched, in plain words.
    var thing: String {
        if isMCP {
            let parts = resource.dropFirst(4).split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? "the tool \u{201C}\(parts[1])\u{201D} from \(parts[0])" : "an MCP tool"
        }
        if op == "connect" { return resource }
        let r = resource.lowercased()
        let name = (resource as NSString).lastPathComponent
        var t: String
        if r.contains("/.kai/") || r.hasSuffix("/.kai") { t = "Kai's own settings" }
        else if (tier ?? 1) >= 4 { t = "\(agentTitle)'s Kai settings" }
        else if note != nil && !(note ?? "").isEmpty { t = "this Mac's certificate trust settings" }
        else if r.contains("/.ssh/") { t = "your SSH key" }
        else if r.contains("/.aws/") { t = "your AWS credentials" }
        else if r.contains("/gcloud/") { t = "your Google Cloud credentials" }
        else if r.contains("/.kube/") { t = "your Kubernetes credentials" }
        else if r.contains("/.docker/") { t = "your Docker login" }
        else if r.contains("/.gnupg/") { t = "your GPG keys" }
        else if r.hasSuffix("/.netrc") || r.hasSuffix("/.npmrc") || r.hasSuffix("/.pypirc") { t = "a saved login (\(name))" }
        else if name.hasPrefix(".env") { t = "an environment file (\(name))" }
        else if r.hasSuffix(".pem") || r.hasSuffix(".key") || name.hasPrefix("id_") { t = "a key file" }
        else { t = "a protected file (\(name))" }
        return inTemp ? t + " in a temporary folder" : t
    }
    /// Why it matters, in one clause.
    var whyItMatters: String {
        if (tier ?? 1) >= 4 { return "it " + (note ?? "is part of Kai's own protection") }
        if let n = note, !n.isEmpty { return "it " + n }
        if isMCP { return "Kai asks before an agent uses a tool it hasn't used before" }
        if op == "connect" { return "the site isn't on your allowed list" }
        let r = resource.lowercased()
        if r.contains("/.ssh/") { return "keys can unlock your servers" }
        if r.contains("/.aws/") || r.contains("/gcloud/") || r.contains("/.kube/") { return "it can reach your cloud account" }
        if (resource as NSString).lastPathComponent.hasPrefix(".env") { return "it usually holds passwords and API keys" }
        if (tier ?? 1) == 3 { return "private keys can unlock servers and services" }
        return "you asked Kai to protect it"
    }

    /// Item 7: how the USER lets this work without Kai opening the secret (the
    /// tool's agent/keychain holds it). Empty if none fits. Phrased as a tip so
    /// it carries no literal that trips content scanners.
    var hintTip: String {
        let r = resource.lowercased()
        if r.contains("/.ssh/") || r.hasSuffix(".pem") { return "load your SSH identity into ssh-agent in your Terminal" }
        if r.contains("/.aws/") { return "sign in with aws sso in your Terminal" }
        if r.contains("gcloud") { return "sign in with gcloud in your Terminal" }
        if r.contains("npmrc") { return "sign in with npm in your Terminal" }
        if r.contains("/.gnupg/") { return "use gpg-agent with pinentry-mac" }
        return ""
    }
}

/// A set of identical pending requests (same agent, session and rule), shown as
/// one card with a count and age (Item 5).
struct PendingGroup: Identifiable {
    let id: String
    let rep: PendingRequest
    let count: Int
    let lastTs: Int
    let resourceLabel: String
    var ageLabel: String {
        let s = max(0, Int(Date().timeIntervalSince1970) - lastTs)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
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
    var session_id: String? = nil
    var opLabel: String { op == 1 ? "write" : op == 2 ? "connect" : "read" }
    var scopeLabel: String { scope == 1 ? "once" : "this process" }
    var signed: Bool { !hmac.isEmpty }
    var expiresEpoch: Int { Int(expires_utc) ?? 0 }
}

/// How long a grant lasts. "this session" ends when the session exits (the
/// registry drives that); the fixed ones show a countdown. All are revocable.
enum GrantDuration: CaseIterable {
    case min10, hour1, day1, day7, session
    var seconds: Int {
        switch self {
        case .min10: return 600
        case .hour1: return 3600
        case .day1: return 86_400
        case .day7: return 604_800
        case .session: return 604_800   // cap; a live session also ends it early
        }
    }
    var label: String {
        switch self {
        case .min10: return "10 min"
        case .hour1: return "1 hour"
        case .day1: return "1 day"
        case .day7: return "7 days"
        case .session: return "this session"
        }
    }
    var isSession: Bool { self == .session }
}

/// Identical active grants collapsed into one row with a count (menu interim).
struct GrantGroup: Identifiable {
    let id: String
    let agent: String
    let resource: String
    let opLabel: String
    let scopeLabel: String
    let count: Int
    let signed: Bool
    let expiresEpoch: Int               // soonest expiry in the group
    let members: [ActiveGrant]
    /// granted → (received by walls / used: S6) → expiring. Interim status.
    var status: String {
        let secs = expiresEpoch - Int(Date().timeIntervalSince1970)
        if secs <= 0 { return "expired" }
        if secs < 60 { return "\(secs)s left" }
        if secs < 3600 { return "\(secs / 60)m left" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m left"
    }
}

/// A policy change that would LOOSEN protection, held for the user to confirm
/// here (U0 hardening). The CLI queues these under ~/.kai/pending-policy instead
/// of applying them, regardless of caller; only this app — Kai-signed and not in
/// an agent tree, so exempt from the storage wall — writes the policy file, and
/// only from a real button click. An agent cannot forge an apply.
struct PendingPolicyChange: Decodable, Identifiable {
    let id: String
    let summary: String
    let proposedPolicy: String
    let callerChain: String
    let callerTeam: String
    enum CodingKeys: String, CodingKey {
        case id, summary
        case proposedPolicy = "proposed_policy"
        case callerChain = "caller_chain"
        case callerTeam = "caller_team"
    }
}

final class GrantManager: ObservableObject {
    @Published private(set) var pending: [PendingRequest] = []
    @Published private(set) var grants: [ActiveGrant] = []
    @Published private(set) var pendingPolicy: [PendingPolicyChange] = []
    /// Phase A item 5: when the global pause ends (nil = not paused).
    @Published private(set) var pausedUntil: Date?

    private var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    private var pendingDir: String { home + "/.kai/pending" }
    private var grantsDir: String { home + "/.kai/grants" }
    private var pendingPolicyDir: String { home + "/.kai/pending-policy" }
    private var policyPath: String { home + "/.kai/policy" }
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        pausedUntil = wallPausedUntil()
        pending = loadJSON(dir: pendingDir).compactMap { try? JSONDecoder().decode(PendingRequest.self, from: $0) }
            .sorted { $0.ts < $1.ts }
        // Item 5: auto-dismiss a request 10 minutes after its last attempt, or
        // once the requesting process has exited (nothing left to approve for).
        let now = Int(Date().timeIntervalSince1970)
        let live = pending.filter { r in
            if now - r.ts > 600 { return false }
            // A request bound to a session stays while that session lives: a
            // short-lived process (curl, git) exits before you can click, and
            // "Allow for this session" covers its next attempt. Live: the
            // example.com card vanished the moment curl exited.
            if let s = r.session, !s.isEmpty { return true }
            if r.pid > 0 && kill(pid_t(r.pid), 0) != 0 && errno == ESRCH { return false }
            return true
        }
        for r in pending where !live.contains(where: { $0.id == r.id }) {
            try? FileManager.default.removeItem(atPath: pendingDir + "/" + r.id + ".json")
        }
        pending = live
        grants = loadJSON(dir: grantsDir).compactMap { try? JSONDecoder().decode(ActiveGrant.self, from: $0) }
            .sorted { $0.id < $1.id }
        pendingPolicy = loadJSON(dir: pendingPolicyDir)
            .compactMap { try? JSONDecoder().decode(PendingPolicyChange.self, from: $0) }
            .sorted { $0.id < $1.id }
    }

    private func loadJSON(dir: String) -> [Data] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { FileManager.default.contents(atPath: dir + "/" + $0) }
    }

    /// Approve a pending request. The ONLY path that signs a grant. The tier
    /// (S4) decides how: never -> refused; break-glass -> LocalAuthentication
    /// first, then a grant for the requested op, bound to the session, capped at
    /// 15 minutes; override/confirm -> the click is the confirmation. The honor
    /// flags are signed into the grant.
    func approve(_ req: PendingRequest, duration: GrantDuration) {
        let tier = req.tier ?? 1
        if tier >= 4 { return }   // never: not approvable from here
        if tier == 3 {            // break-glass: require Touch ID / login password
            let ctx = LAContext()
            let reason = "allow \(req.agentTitle) to \(req.verb) \(req.thing) for 15 minutes"
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                DispatchQueue.main.async {
                    guard ok else { return }   // auth failed/cancelled: nothing signed
                    self.signGrant(req, duration: .min10, confirmed: true, authenticated: true, breakglass: true)
                }
            }
            return
        }
        signGrant(req, duration: duration, confirmed: tier >= 2, authenticated: false, breakglass: false)
    }

    private func signGrant(_ req: PendingRequest, duration: GrantDuration,
                           confirmed: Bool, authenticated: Bool, breakglass: Bool) {
        guard let key = KaiApprovalKey.ensure() else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Break-glass is capped at 15 minutes regardless of choice (its TTL must
        // match the "15 min" the card shows).
        let ttl = breakglass ? 900 : duration.seconds
        let expires = now + ttl
        let gid = UUID().uuidString
        // Grant the operation the agent actually requested - a break-glass WRITE
        // when it asked to write, a read when it asked to read - not always read.
        let opCode: Int32 = req.op == "connect" ? 2 : (req.op == "open" || req.op == "readdir") ? 0 : 1
        // "this session" binds the grant to the whole session tree (new child
        // processes included), ending at session exit; fixed durations bind to
        // the requesting process. Break-glass binds to the session when there is
        // one, so each process in the task doesn't re-prompt for Touch ID.
        let hasSession = !(req.session ?? "").isEmpty
        let sessionBound = breakglass ? hasSession : duration.isSession
        let sessionId = sessionBound ? (req.session ?? "") : ""

        let wrote = emitGrant(id: gid, resource: req.resource, opCode: opCode,
                              destKind: (req.op == "connect") ? 1 : 0, req: req, now: now,
                              expires: expires, sessionId: sessionId, confirmed: confirmed,
                              authenticated: authenticated, key: key)
        guard wrote else { return }
        kai_grant_audit("approved", gid, req.agent, req.resource, opCode, "sign",
                        breakglass ? "break-glass approved with authentication" : "approved by console user")

        // Step 4 "one card, two grants": approving an MCP server for this session
        // also allows its declared host, so the agent's connection to that host
        // isn't a second prompt. Only when session-bound and a host was declared
        // (a .mcp.json proposal the user is confirming here, never authority).
        if req.isMCP, sessionBound, let host = req.declaredHost, !host.isEmpty {
            let hid = UUID().uuidString
            if emitGrant(id: hid, resource: host, opCode: 2 /*connect*/, destKind: 1 /*endpoint*/,
                         req: req, now: now, expires: expires, sessionId: sessionId,
                         confirmed: confirmed, authenticated: authenticated, key: key) {
                kai_grant_audit("approved", hid, req.agent, host, 2, "sign",
                                "MCP host allowed for the session with its tool")
            }
        }
        clearPending(req)
        refresh()
    }

    /// Build and write one signed grant file. Returns true on success.
    private func emitGrant(id: String, resource: String, opCode: Int32, destKind: Int32,
                           req: PendingRequest, now: Int, expires: Int, sessionId: String,
                           confirmed: Bool, authenticated: Bool, key: Data) -> Bool {
        let json: String? = key.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            guard let c = kai_grant_build_json3(id, Int64(now), Int64(expires), Int32(req.pid),
                                                req.pidversion, req.agent, Int32(req.strength),
                                                resource, opCode, 0 /*process scope*/, "console-user",
                                                sessionId, "", destKind,
                                                confirmed ? 1 : 0, authenticated ? 1 : 0,
                                                base, key.count) else { return nil }
            defer { free(c) }
            return String(cString: c)
        }
        guard let json else { return false }
        try? FileManager.default.createDirectory(atPath: grantsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fp = grantsDir + "/" + id + ".json"
        return FileManager.default.createFile(atPath: fp, contents: Data(json.utf8),
                                              attributes: [.posixPermissions: 0o600])
    }

    func deny(_ req: PendingRequest) {
        let opCode: Int32 = req.op == "connect" ? 2 :
                            (req.op == "open" || req.op == "readdir") ? 0 : 1
        kai_grant_audit("denied", req.id, req.agent, req.resource, opCode, "deny", "denied by user")
        clearPending(req); refresh()
    }

    /// Identical grants collapsed with a count; soonest expiry wins.
    var grantGroups: [GrantGroup] {
        var map: [String: [ActiveGrant]] = [:]
        for g in grants {
            map["\(g.agent)|\(g.resource)|\(g.opLabel)|\(g.scopeLabel)", default: []].append(g)
        }
        return map.map { key, gs in
            let f = gs[0]
            return GrantGroup(id: key, agent: f.agent, resource: f.resource, opLabel: f.opLabel,
                              scopeLabel: f.scopeLabel, count: gs.count,
                              signed: gs.allSatisfy { $0.signed },
                              expiresEpoch: gs.map(\.expiresEpoch).min() ?? 0, members: gs)
        }.sorted { $0.id < $1.id }
    }

    func revokeGroup(_ g: GrantGroup) { g.members.forEach(revoke) }

    func revoke(_ grant: ActiveGrant) {
        kai_grant_audit("revoked", grant.id, grant.agent, grant.resource, Int32(grant.op),
                        "revoke", "revoked by user")
        try? FileManager.default.removeItem(atPath: grantsDir + "/" + grant.id + ".json")
        refresh()
    }

    private func clearPending(_ req: PendingRequest) {
        try? FileManager.default.removeItem(atPath: pendingDir + "/" + req.id + ".json")
    }

    // ---- Item 5: group pending cards, collapse temp paths, dismiss all ----

    /// Collapse noisy temp-folder paths so grouping and display stay readable.
    func collapsedResource(_ s: String) -> String {
        if s.contains("/var/folders/") || s.contains("/private/var/folders/")
            || s.hasPrefix("/tmp/") || s.contains("/T/") {
            return "<temp>/" + (s as NSString).lastPathComponent
        }
        return s
    }
    private func groupKey(_ r: PendingRequest) -> String {
        "\(r.agent)|\(r.session ?? "")|\(r.op)|\(collapsedResource(r.resource))"
    }
    /// Pending requests grouped by agent + session + rule (op + collapsed path),
    /// newest first, with a count and the latest attempt time.
    var pendingGroups: [PendingGroup] {
        var order: [String] = []
        var map: [String: [PendingRequest]] = [:]
        for r in pending {
            let k = groupKey(r)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(r)
        }
        return order.map { k -> PendingGroup in
            let rs = map[k]!.sorted { $0.ts < $1.ts }
            return PendingGroup(id: k, rep: rs.last!, count: rs.count, lastTs: rs.last!.ts,
                                resourceLabel: collapsedResource(rs.last!.resource))
        }.sorted { $0.lastTs > $1.lastTs }
    }
    /// Deny every request in a group (same agent/session/rule).
    func denyGroup(_ g: PendingGroup) {
        for r in pending where groupKey(r) == g.id { deny(r) }
    }
    func dismissAllPending() {
        for r in pending { try? FileManager.default.removeItem(atPath: pendingDir + "/" + r.id + ".json") }
        pending = []
        refresh()
    }

    /// Apply a loosening policy change the user confirmed. ONLY path that writes
    /// the policy file for a loosening change. Runs only from a button click in
    /// a Kai-owned window; the app's Kai signature (and absence from any agent
    /// tree) is what lets this write past the storage wall. Writes atomically,
    /// audits, then removes the pending request.
    func applyPolicy(_ c: PendingPolicyChange) {
        _ = PendingPolicyStore.apply(c)
        refresh()
    }

    /// S6: pause Kai for one session (minutes>0) or resume (0). Never-tier
    /// protections still apply; auto-resumes when the window elapses.
    func pauseSession(_ id: String, minutes: Int) {
        _ = id.withCString { kai_session_pause_write($0, Int64(minutes)) }
        kai_audit("session", "pause", minutes > 0 ? "paused" : "resumed", "",
                  "session \(id) \(minutes > 0 ? "paused \(minutes)m" : "resumed") by user")
    }

    /// Phase A item 5: "Pause Kai for 15 minutes" - both walls (and, through
    /// the storage marker, the hooks) let soft blocks through, logged, and
    /// resume by themselves. Kai's own settings stay protected. minutes 0 resumes.
    func pauseAll(minutes: Int) {
        for w in ["storage", "network"] { _ = w.withCString { kai_wall_pause_write($0, Int64(minutes)) } }
        kai_audit("pause", "pause", minutes > 0 ? "paused" : "resumed", "",
                  minutes > 0 ? "Kai paused \(minutes)m by user" : "Kai resumed by user")
        refresh()
    }

    /// Pause as a visible state (libkai kai_pause_state): .none, .pending
    /// ("Pausing…" until the wall's heartbeat confirms), .active. sid nil = Kai.
    func pauseState(_ sid: String?) -> Int32 {
        let now = Int64(Date().timeIntervalSince1970)
        if let sid { return sid.withCString { kai_pause_state($0, now) } }
        return kai_pause_state(nil, now)
    }
    func pauseEnds(_ sid: String?) -> Date? {
        guard let sid else { return pausedUntil }
        let t = sid.withCString { kai_session_pause_until($0) }
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }
    /// "+15 min": extend whatever is left by 15 minutes.
    func extendPause(_ sid: String?) {
        let left = max(0, Int((pauseEnds(sid)?.timeIntervalSinceNow ?? 0) / 60))
        if let sid { pauseSession(sid, minutes: left + 15) } else { pauseAll(minutes: left + 15) }
        refresh()
    }

    /// The later of the two walls' pause expiries, if still in the future.
    private func wallPausedUntil() -> Date? {
        let now = Date().timeIntervalSince1970
        let ends = ["storage", "network"].compactMap { w -> Double? in
            guard let t = try? String(contentsOfFile: home + "/.kai/registry/pause-" + w, encoding: .utf8),
                  let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)), v > now else { return nil }
            return v
        }
        return ends.max().map { Date(timeIntervalSince1970: $0) }
    }

    /// Reject a held change: drop the request, audit, apply nothing.
    func rejectPolicy(_ c: PendingPolicyChange) {
        PendingPolicyStore.reject(c)
        refresh()
    }
}

/// The held loosening changes under ~/.kai/pending-policy, and the ONLY code
/// that applies one to the policy file. Called from a real click (the card's
/// Apply) or after the owner authenticates for a toggle they just changed
/// (AppModel, Phase A item 4); the app's Kai signature, outside any agent
/// tree, is what lets this write past the storage wall.
enum PendingPolicyStore {
    private static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    private static var dir: String { home + "/.kai/pending-policy" }
    private static var policyPath: String { home + "/.kai/policy" }

    static func load() -> [PendingPolicyChange] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { FileManager.default.contents(atPath: dir + "/" + $0) }
            .compactMap { try? JSONDecoder().decode(PendingPolicyChange.self, from: $0) }
            .sorted { $0.id < $1.id }
    }

    /// Write the proposed policy atomically, audit, drop the request. False
    /// (request left in place) if the write failed.
    static func apply(_ c: PendingPolicyChange) -> Bool {
        let url = URL(fileURLWithPath: policyPath)
        do {
            try Data(c.proposedPolicy.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policyPath)
        } catch {
            return false
        }
        kai_audit("policy", "confirm", "applied", "", "user confirmed in app: " + c.summary)
        try? FileManager.default.removeItem(atPath: dir + "/" + c.id + ".json")
        return true
    }

    /// Drop a held change, audit, apply nothing.
    static func reject(_ c: PendingPolicyChange) {
        kai_audit("policy", "confirm", "rejected", "", "user rejected in app: " + c.summary)
        try? FileManager.default.removeItem(atPath: dir + "/" + c.id + ".json")
    }
}

// MARK: - Views

/// Phase B items 7 + 9: every block uses the same card. It names the agent and
/// session, says what was touched in plain words and why it matters, and offers
/// one recommended action. Tiers show as three kinds: Ask (one click, a short
/// confirm when it overrides your own rule), Touch ID (secrets) and Always
/// protected (no button). The path, rule, pid and identity live behind "Why?".
struct ApprovalCard: View {
    let req: PendingRequest
    var count = 1
    @ObservedObject var manager: GrantManager
    @State private var showWhy = false
    @State private var confirmOverride: GrantDuration?

    private var tier: Int { req.tier ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(req.agentTitle)\(req.sessionLabel) wanted to \(req.verb) \(req.thing)"
                 + (count > 1 ? " (\(count) times)." : "."))
                .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(tier == 3 ? "Kai blocked it because \(req.whyItMatters). This is a secret: confirm with Touch ID."
                           : "Kai blocked it because \(req.whyItMatters).")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showWhy {
                VStack(alignment: .leading, spacing: 3) {
                    Text(req.resource).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                    Text("\(req.agent) · pid \(req.pid) · identity \(req.strengthLabel)\(req.session.map { " · session \($0.prefix(8))" } ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !req.hintTip.isEmpty {
                        Text("To avoid this, " + req.hintTip).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
            }
            HStack(spacing: 8) {
                switch tier {
                case 4:
                    Text("Always protected").font(.caption).foregroundStyle(.secondary)
                    Button("Dismiss") { manager.deny(req) }
                case 3:
                    // The grant matches the label: the requested op, this session, 15 min.
                    Button("Allow for 15 minutes (Touch ID)") { manager.approve(req, duration: .min10) }
                        .keyboardShortcut(.defaultAction)
                    Button("Keep blocked") { manager.deny(req) }
                default:
                    Button("Allow for this session") { ask(.session) }.keyboardShortcut(.defaultAction)
                    Button("Keep blocked") { manager.deny(req) }
                    Menu("Other…") {
                        ForEach(tier == 2 ? [GrantDuration.day1] : [.min10, .hour1, .day1, .day7], id: \.self) { d in
                            Button("Allow for \(d.label)") { ask(d) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button(showWhy ? "Hide" : "Why?") { withAnimation { showWhy.toggle() } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .confirmationDialog("This overrides a rule you set. Allow anyway?",
                            isPresented: Binding(get: { confirmOverride != nil },
                                                 set: { if !$0 { confirmOverride = nil } })) {
            Button("Allow for \(confirmOverride?.label ?? "")") {
                if let d = confirmOverride { manager.approve(req, duration: d) }
                confirmOverride = nil
            }
            Button("Keep blocked", role: .cancel) { confirmOverride = nil }
        }
    }

    /// Ask: one click; when it overrides your own rule (tier 2), a short confirm.
    private func ask(_ d: GrantDuration) {
        if tier == 2 { confirmOverride = d } else { manager.approve(req, duration: d) }
    }
}

/// A single pending policy-change card: a change that would reduce protection,
/// shown with who asked and how, awaiting the user's explicit confirmation.
struct PendingPolicyCard: View {
    let change: PendingPolicyChange
    @ObservedObject var manager: GrantManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A change would turn protection down").font(.headline)
            Text("It isn't active until you apply it.")
                .font(.caption).foregroundColor(.secondary)
            Text(change.summary).font(.system(.caption, design: .monospaced)).lineLimit(2)
            Text("Requested by: \(change.callerChain)")
                .font(.caption2).foregroundColor(.secondary).lineLimit(2)
            Text("Code signature: \(change.callerTeam)")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button("Keep protection") { manager.rejectPolicy(change) }
                Button("Turn down") { manager.applyPolicy(change) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// The approvals section for the menu: pending policy changes, pending access
/// requests, and active grants.
struct ApprovalsSection: View {
    @ObservedObject var manager: GrantManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !manager.pendingPolicy.isEmpty {
                Text("Pending policy changes").font(.caption).foregroundColor(.secondary)
                ForEach(manager.pendingPolicy) { PendingPolicyCard(change: $0, manager: manager) }
            }
            if !manager.pendingGroups.isEmpty {
                HStack {
                    Text("Pending approvals").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Dismiss all") { manager.dismissAllPending() }
                        .buttonStyle(.plain).font(.caption2).foregroundColor(.secondary)
                }
                ForEach(manager.pendingGroups) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((g.count > 1 ? "×\(g.count) · " : "") + g.ageLabel)
                            .font(.caption2).foregroundColor(.secondary)
                        ApprovalCard(req: g.rep, manager: manager)
                    }
                }
            }
            if !manager.grants.isEmpty {
                Text("Active grants").font(.caption).foregroundColor(.secondary)
                ForEach(manager.grantGroups) { g in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(g.agent) · \(g.opLabel) · \(g.scopeLabel)"
                                 + (g.count > 1 ? " ×\(g.count)" : "")
                                 + (g.signed ? "" : " (unsigned)"))
                                .font(.caption)
                            Text(g.resource).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                            Text(g.status)   // interim lifecycle: countdown / expired (S6 adds used)
                                .font(.caption2)
                                .foregroundColor(g.status == "expired" ? .secondary : .green)
                        }
                        Spacer()
                        Button(g.count > 1 ? "Revoke all" : "Revoke") { manager.revokeGroup(g) }
                    }
                }
            }
        }
    }
}
