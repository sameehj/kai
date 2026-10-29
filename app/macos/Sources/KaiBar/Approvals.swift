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
import AppKit
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
    var identity: String? = nil      // B2: the agent's verified signing identity ("" / nil = unverified)
    var hostKnown: Bool? = nil       // B2: false = a connection with no known hostname
    /// B2 hostname honesty: the decision had only an address, so the card says
    /// so and offers this one connection; no rule is made from a guess.
    var unknownHost: Bool { op == "connect" && hostKnown == false }
    var verifiedIdentity: String? { (identity ?? "").isEmpty ? nil : identity }
    /// Keep blocked can be remembered, and a rule made, only for a verified
    /// agent and a real hostname.
    var rememberable: Bool { op == "connect" && !unknownHost && verifiedIdentity != nil }
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
        if op == "connect" { return unknownHost ? "\(resource) (hostname unknown)" : resource }
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
        if unknownHost { return "it isn't on your allowed list, and Kai couldn't learn which site this address is" }
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
    var created_utc: String? = nil
    var confirmed: Int? = 0
    var authenticated: Int? = 0
    var opLabel: String { op == 1 ? "write" : op == 2 ? "connect" : "read" }
    /// B2 grant authority: who approved it, how, and when.
    var authorityLabel: String {
        let how = (authenticated ?? 0) == 1 ? "with Touch ID or your password"
                : (confirmed ?? 0) == 1 ? "with a click and a confirm" : "with a click"
        let when = Int(created_utc ?? "").map {
            Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        return "Given by you in Kai \(how)" + (when.isEmpty ? "" : " · \(when)")
    }
    /// B1: scope and duration always agree. A grant bound to a session lasts
    /// until that session ends (its expiry is only a cap), so it never shows
    /// "this process · 7 days".
    var isSession: Bool { !(session_id ?? "").isEmpty }
    var scopeLabel: String { scope == 1 ? "once" : isSession ? "this session" : "this process" }
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
    var isSession = false
    let count: Int
    let signed: Bool
    let expiresEpoch: Int               // soonest expiry in the group
    let members: [ActiveGrant]
    var isExpired: Bool { expiresEpoch - Int(Date().timeIntervalSince1970) <= 0 }
    /// What the row says: the resource in plain words (a host, or a file's
    /// name), so no permission row is without its resource.
    var resourceLabel: String {
        if resource.hasPrefix("mcp:") { return "MCP " + resource.dropFirst(4) }
        if resource.contains("/") { return (resource as NSString).lastPathComponent }
        return resource
    }
    /// Time left, in the same terms as the scope.
    var status: String {
        let secs = expiresEpoch - Int(Date().timeIntervalSince1970)
        if secs <= 0 { return "expired" }
        if isSession { return "until the session ends" }
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
    @Published private(set) var rules: [DecisionRule] = []
    /// B2: agents whose telemetry Kai blocked silently (one passive hint each).
    @Published private(set) var telemetryHints: [String] = []
    /// Phase A item 5: when the global pause ends (nil = not paused).
    @Published private(set) var pausedUntil: Date?

    private var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    private var pendingDir: String { home + "/.kai/pending" }
    private var grantsDir: String { home + "/.kai/grants" }
    private var pendingPolicyDir: String { home + "/.kai/pending-policy" }
    private var rulesDir: String { home + "/.kai/rules" }
    private var hintsDir: String { home + "/.kai/hints" }
    private var policyPath: String { home + "/.kai/policy" }
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    /// B1: the app is the only writer of the grants folder, so it alone drops
    /// expired / session-ended / invalid grants and audits each once (the
    /// extensions' stores are read-only).
    private var cleanupStore: OpaquePointer?
    private var seenPending = Set<String>()   // a NEW card plays the "needs you" sound once
    private var primed = false                // ...not the ones already there at launch
    private func cleanupGrants() {
        if cleanupStore == nil, let key = KaiApprovalKey.ensure() {
            cleanupStore = key.withUnsafeBytes { raw -> OpaquePointer? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return kai_approval_store_open(nil, grantsDir, base, key.count, 0)
            }
        }
        if let s = cleanupStore { _ = kai_approval_store_reload(s, 1) }
    }

    func refresh() {
        cleanupGrants()
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
            // A card from a signed agent can be allowed by identity (1 hour)
            // after the process has gone (gh, curl exit at once): keep it.
            if r.rememberable { return true }
            if r.pid > 0 && kill(pid_t(r.pid), 0) != 0 && errno == ESRCH { return false }
            return true
        }
        for r in pending where !live.contains(where: { $0.id == r.id }) {
            try? FileManager.default.removeItem(atPath: pendingDir + "/" + r.id + ".json")
        }
        let fresh = live.filter { r in !seenPending.contains(r.id) }
        if primed && !fresh.isEmpty { KaiSounds.approvalNeeded() }
        seenPending.formUnion(live.map(\.id)); primed = true
        pending = live
        grants = loadJSON(dir: grantsDir).compactMap { try? JSONDecoder().decode(ActiveGrant.self, from: $0) }
            .sorted { $0.id < $1.id }
        rules = loadJSON(dir: rulesDir).compactMap { try? JSONDecoder().decode(DecisionRule.self, from: $0) }
            .sorted { $0.created < $1.created }
        // The app is the rules folder's only writer: drop ended 1-hour allows.
        for r in rules where r.hasEnded {
            kai_grant_audit("expired", r.id, r.agent, r.dest, 2, "expire", "1-hour allow ended")
            try? FileManager.default.removeItem(atPath: rulesDir + "/" + r.id + ".json")
        }
        rules.removeAll(where: \.hasEnded)
        telemetryHints = ((try? FileManager.default.contentsOfDirectory(atPath: hintsDir)) ?? [])
            .filter { $0.hasPrefix("telemetry-") }.map { String($0.dropFirst(10)) }.sorted()
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
    /// B2: a connection with no known hostname: allow this one connection (a
    /// one-shot grant for this process and address), never a session or rule.
    func approveOnce(_ req: PendingRequest) {
        signGrant(req, duration: .min10, confirmed: false, authenticated: false, breakglass: false, oneShot: true)
    }

    func approve(_ req: PendingRequest, duration: GrantDuration) {
        if req.unknownHost { approveOnce(req); return }
        let tier = req.tier ?? 1
        if tier >= 4 { return }   // never: not approvable from here
        if tier == 3 {            // break-glass: require Touch ID / login password
            let reason = "allow \(req.agentTitle) to \(req.verb) \(req.thing) for 15 minutes"
            // break-glass asks every time: never the 30-minute window
            Task {
                guard await OwnerAuth.shared.confirm(reason, everyTime: true) else { return }
                await MainActor.run {
                    self.signGrant(req, duration: .min10, confirmed: true, authenticated: true, breakglass: true)
                }
            }
            return
        }
        signGrant(req, duration: duration, confirmed: tier >= 2, authenticated: false, breakglass: false)
    }

    private func signGrant(_ req: PendingRequest, duration: GrantDuration,
                           confirmed: Bool, authenticated: Bool, breakglass: Bool, oneShot: Bool = false) {
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
        let sessionBound = oneShot ? false : breakglass ? hasSession : duration.isSession
        let sessionId = sessionBound ? (req.session ?? "") : ""

        let wrote = emitGrant(id: gid, resource: req.resource, opCode: opCode,
                              destKind: (req.op == "connect") ? 1 : 0, req: req, now: now,
                              expires: expires, sessionId: sessionId, confirmed: confirmed,
                              authenticated: authenticated, key: key, scope: oneShot ? 1 : 0)
        guard wrote else { return }
        KaiSounds.permissionGranted()
        Notifier.say("Kai allowed \(req.agentTitle) to \(req.verb) \(req.thing)",
                     oneShot ? "This connection only." : sessionBound ? "For this session." : "For \(duration.label).")
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
                           confirmed: Bool, authenticated: Bool, key: Data, scope: Int32 = 0) -> Bool {
        let json: String? = key.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            guard let c = kai_grant_build_json3(id, Int64(now), Int64(expires), Int32(req.pid),
                                                req.pidversion, req.agent, Int32(req.strength),
                                                resource, opCode, scope /*0 process, 1 once*/, "console-user",
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

    /// B2: Keep blocked. For a verified agent and a real hostname it is
    /// remembered (a signed rule): later attempts are audited, not carded.
    /// Reversible in Settings → Permissions. Otherwise it just dismisses.
    func keepBlocked(_ req: PendingRequest) {
        if req.rememberable, let ident = req.verifiedIdentity,
           writeRule(kind: Int32(KAI_RULE_KEEP_BLOCKED), req: req, identity: ident, authenticated: false) {
            kai_grant_audit("denied", req.id, req.agent, req.resource, 2, "deny",
                            "kept blocked by user; remembered for \(ident)")
            for r in pending where r.op == "connect" && r.resource == req.resource && r.identity == req.identity {
                clearPending(r)
            }
            refresh(); return
        }
        deny(req)
    }

    /// B2: a persistent Allow rule, made deliberately (More… → Create a rule),
    /// confirmed with owner authentication, bound to the verified identity.
    func createRule(_ req: PendingRequest) {
        guard req.rememberable, let ident = req.verifiedIdentity else { return }
        Task {
            guard await OwnerAuth.shared.confirm("allow \(req.agentTitle) to connect to \(req.resource) in every future session")
            else { return }
            await MainActor.run {
                if self.writeRule(kind: Int32(KAI_RULE_ALLOW), req: req, identity: ident, authenticated: true) {
                    KaiSounds.permissionGranted()
                    Notifier.say("Kai rule: \(req.agentTitle) may connect to \(req.resource)", "In every session, until you remove it.")
                    kai_grant_audit("approved", req.id, req.agent, req.resource, 2, "sign",
                                    "rule created with owner authentication for \(ident)")
                    for r in self.pending where r.op == "connect" && r.resource == req.resource
                        && r.identity == req.identity { self.clearPending(r) }
                }
                self.refresh()
            }
        }
    }

    /// Fix 2: no session to bind to: allow this signed agent to reach this
    /// host for one hour, in any of its sessions. One click, like the other
    /// time-boxed allows; "Create a rule…" stays the permanent option.
    func allowForHour(_ req: PendingRequest) {
        guard req.rememberable, let ident = req.verifiedIdentity else { return }
        if writeRule(kind: Int32(KAI_RULE_ALLOW), req: req, identity: ident, authenticated: false, ttl: 3600) {
            KaiSounds.permissionGranted()
            kai_grant_audit("approved", req.id, req.agent, req.resource, 2, "sign",
                            "allowed for 1 hour for \(ident)")
            Notifier.say("Kai allowed \(req.agentTitle) to reach \(req.resource)", "For 1 hour.")
            for r in pending where r.op == "connect" && r.resource == req.resource && r.identity == req.identity {
                clearPending(r)
            }
        }
        refresh()
    }

    private func writeRule(kind: Int32, req: PendingRequest, identity: String, authenticated: Bool,
                           ttl: Int = 0) -> Bool {
        guard let key = KaiApprovalKey.ensure() else { return false }
        let rid = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let json: String? = key.withUnsafeBytes { raw -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                  let c = kai_rule_build_json_until(rid, kind, identity, req.agent, req.resource, 2,
                                                    now, ttl > 0 ? now + Int64(ttl) : 0, authenticated ? 1 : 0,
                                              base, key.count) else { return nil }
            defer { free(c) }
            return String(cString: c)
        }
        guard let json else { return false }
        try? FileManager.default.createDirectory(atPath: rulesDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return FileManager.default.createFile(atPath: rulesDir + "/" + rid + ".json", contents: Data(json.utf8),
                                              attributes: [.posixPermissions: 0o600])
    }

    /// Removing a rule never lowers protection (an Allow goes away, or a Keep
    /// blocked goes back to asking), so it is one click.
    func removeRule(_ r: DecisionRule) {
        kai_grant_audit("revoked", r.id, r.agent, r.dest, 2, "revoke",
                        r.kind == "allow" ? "rule removed by user" : "keep blocked removed by user")
        try? FileManager.default.removeItem(atPath: rulesDir + "/" + r.id + ".json")
        refresh()
    }

    // ---- Batch 2: acting on an Activity row ----

    /// A request built from an audit record, so an Activity row can use the
    /// same approve / rule paths as a card. Only network records with a host.
    func request(from e: AuditEvent) -> PendingRequest {
        PendingRequest(id: "act-" + String(e.id.prefix(12)), agent: e.agentKey, pid: 0, pidversion: 0,
                       strength: 1, resource: e.target ?? "", op: "connect",
                       ts: Int(e.date?.timeIntervalSince1970 ?? 0), session: e.session,
                       identity: e.identity, hostKnown: !e.isUnknownHost)
    }
    /// A live card for the same thing, if one is still waiting.
    func pendingFor(_ e: AuditEvent) -> PendingRequest? {
        pending.last { $0.resource == (e.target ?? "") && $0.agent == e.agentKey }
    }
    /// "Allow for this session" from a row: a session-bound grant (it covers
    /// any process in that session, so the original pid isn't needed).
    func allowForSession(_ e: AuditEvent) {
        guard let s = e.session, !s.isEmpty else { return }
        approve(request(from: e), duration: .session)
    }
    /// The remembered "Keep blocked" behind a row, if any.
    func keptBlockedRule(_ e: AuditEvent) -> DecisionRule? {
        rules.first { !$0.isAllow && $0.dest.caseInsensitiveCompare(e.target ?? "") == .orderedSame
                      && (e.identity == nil || $0.identity == e.identity) }
    }

    // ---- Spec v2.1 B.4: one-time migration of the old category switches ----
    //
    // One switch must not become permanent rules for services never used, and
    // an old Touch ID must not approve new rules. So, per host of the switch:
    //   the agent reached it (audit evidence)  -> a migrated Allow that ends in
    //                                             7 days unless you confirm it
    //                                             now with Touch ID
    //   no evidence                            -> an "asked recently" entry with
    //                                             no permission
    // Exact hosts only: githubusercontent.com doesn't cover
    // raw.githubusercontent.com, and neither is added automatically.

    private var migrationsDir: String { home + "/.kai/migrations" }
    struct MigratedAsk: Codable, Hashable { let agent: String; let host: String; let from: String }

    /// Hosts from an old switch with no evidence: listed, never allowed.
    var migratedAsks: [MigratedAsk] {
        guard let d = FileManager.default.contents(atPath: migrationsDir + "/asked.json"),
              let a = try? JSONDecoder().decode([MigratedAsk].self, from: d) else { return [] }
        return a
    }
    func forgetMigratedAsk(_ m: MigratedAsk) { saveAsks(migratedAsks.filter { $0 != m }); objectWillChange.send() }
    private func saveAsks(_ a: [MigratedAsk]) {
        try? FileManager.default.createDirectory(atPath: migrationsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let d = try? JSONEncoder().encode(a) {
            FileManager.default.createFile(atPath: migrationsDir + "/asked.json", contents: d,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Plan one (agent, host) from switch `from`; returns the report line.
    private func planHost(agent: String, host: String, from: String) -> String {
        if kai_migration_evidence(agent, host) == 1, let idp = kai_agent_verified_identity(agent) {
            if writeMigrated(agent: agent, identity: String(cString: idp), dest: host) {
                kai_grant_audit("approved", "migration", agent, host, 2, "sign",
                                "migrated from the \(from) switch: 7 days unless confirmed (agent reached it)")
                return "\(agent): \(host) allowed for 7 days unless you confirm it (\(agent) reached it before)"
            }
            return "\(agent): \(host) couldn't be written; it will be asked about"
        }
        var asks = migratedAsks
        if !asks.contains(where: { $0.agent == agent && $0.host == host }) {
            asks.append(MigratedAsk(agent: agent, host: host, from: from)); saveAsks(asks)
        }
        return "\(agent): \(host) not allowed (never reached); listed under Asked recently, Kai asks the first time"
    }

    private func writeReport(_ lines: [String]) {
        try? FileManager.default.createDirectory(atPath: migrationsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let text = "Kai replaced the old category switches (migration v2, "
            + Date().formatted(date: .abbreviated, time: .shortened) + "):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n")
            + "\nExact hosts only: githubusercontent.com doesn't cover raw.githubusercontent.com, and neither is added "
            + "automatically. Subdomains such as api.github.com are asked about per host.\n"
        FileManager.default.createFile(atPath: migrationsDir + "/channels.txt", contents: Data(text.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// Migrate "channel <agent>/<switch>" lines. Returns the report and the
    /// lines to remove from the policy.
    @discardableResult
    func migrateChannels(_ lines: [String]) -> (report: [String], done: [String]) {
        var report: [String] = [], done: [String] = []
        for entry in lines {
            let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let agents = parts[0] == "*" ? ["claude", "codex", "cursor"] : [parts[0]]
            var hosts: [String] = []
            var i: Int32 = 0
            while let h = kai_channel_legacy_host(parts[1], i) { hosts.append(String(cString: h)); i += 1 }
            if hosts.isEmpty { report.append("\(entry): unknown switch, removed, nothing migrated") }
            for a in agents { for h in hosts { report.append(planHost(agent: a, host: h, from: parts[1])) } }
            done.append(entry)
        }
        if !report.isEmpty { writeReport(report) }
        refresh()
        return (report, done)
    }

    /// Correct the first migration (Oct 29), which made permanent, authenticated
    /// rules for every host of a switch. Remove exactly those, then plan each
    /// host again. Runs once: the v2 report marks it done.
    func correctEarlierMigration() -> [String] {
        guard let d = FileManager.default.contents(atPath: migrationsDir + "/channels.txt"),
              let text = String(data: d, encoding: .utf8), !text.contains("migration v2") else { return [] }
        var report: [String] = []
        for line in text.split(separator: "\n") {
            // "  claude: allow github.com (exact host, every session) from the code-hosting switch"
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":"), t.contains(": allow "), let fromR = t.range(of: " from the "),
                  let swEnd = t.range(of: " switch", range: fromR.upperBound..<t.endIndex) else { continue }
            let agent = String(t[..<colon])
            let host = t[t.index(colon, offsetBy: 8)...].split(separator: " ").first.map(String.init) ?? ""
            let from = String(t[fromR.upperBound..<swEnd.lowerBound])
            for r in rules where r.isAllow && r.agent == agent && r.dest == host && !r.isTemporary
                && (r.authenticated ?? 0) == 1 && (r.migrated ?? 0) == 0 {
                kai_grant_audit("revoked", r.id, r.agent, r.dest, 2, "revoke",
                                "first migration corrected: an old Touch ID doesn't approve new rules")
                try? FileManager.default.removeItem(atPath: rulesDir + "/" + r.id + ".json")
            }
            refresh()
            report.append(planHost(agent: agent, host: host, from: from))
        }
        writeReport(report)
        refresh()
        return report
    }

    private func writeMigrated(agent: String, identity: String, dest: String) -> Bool {
        guard let key = KaiApprovalKey.ensure() else { return false }
        let rid = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let json: String? = key.withUnsafeBytes { raw -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                  let c = kai_rule_build_json_migrated(rid, identity, agent, dest, 2, now, now + 7 * 86400,
                                                       base, key.count) else { return nil }
            defer { free(c) }
            return String(cString: c)
        }
        guard let json else { return false }
        try? FileManager.default.createDirectory(atPath: rulesDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return FileManager.default.createFile(atPath: rulesDir + "/" + rid + ".json", contents: Data(json.utf8),
                                              attributes: [.posixPermissions: 0o600])
    }

    /// Keep a migrated rule: a fresh owner authentication (never the
    /// 30-minute window), then a normal permanent rule replaces it.
    func confirmMigrated(_ r: DecisionRule) {
        Task {
            guard await OwnerAuth.shared.confirm("keep allowing \(r.agentTitle) to reach \(r.dest) in every session",
                                                 everyTime: true) else { return }
            await MainActor.run {
                guard let key = KaiApprovalKey.ensure() else { return }
                let rid = UUID().uuidString
                let json: String? = key.withUnsafeBytes { raw -> String? in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                          let c = kai_rule_build_json_until(rid, Int32(KAI_RULE_ALLOW), r.identity, r.agent, r.dest, 2,
                                                            Int64(Date().timeIntervalSince1970), 0, 1, base, key.count)
                    else { return nil }
                    defer { free(c) }
                    return String(cString: c)
                }
                if let json, FileManager.default.createFile(atPath: self.rulesDir + "/" + rid + ".json",
                                                            contents: Data(json.utf8),
                                                            attributes: [.posixPermissions: 0o600]) {
                    kai_grant_audit("approved", rid, r.agent, r.dest, 2, "sign",
                                    "migrated rule confirmed with owner authentication")
                    try? FileManager.default.removeItem(atPath: self.rulesDir + "/" + r.id + ".json")
                }
                self.refresh()
            }
        }
    }

    var migratedRules: [DecisionRule] { rules.filter { ($0.migrated ?? 0) == 1 && !$0.hasEnded } }

    func dismissTelemetryHint(_ agent: String) {
        try? FileManager.default.removeItem(atPath: hintsDir + "/telemetry-" + agent)
        refresh()
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
                              scopeLabel: f.scopeLabel, isSession: f.isSession, count: gs.count,
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
        if minutes > 0 { Notifier.say("Kai paused for \(minutes) minutes", PauseText.global) }
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
    @State private var showRule = false

    private var tier: Int { req.tier ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(req.agentTitle)\(req.sessionLabel) wanted to \(req.verb) \(req.thing)"
                 + (count > 1 ? " (\(count) times)." : "."))
                .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if req.op == "connect" && !req.unknownHost {
                Text(HostCatalog.line(req.resource) + " Kai doesn't know why this was requested.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(tier == 3 ? "Kai blocked it because \(req.whyItMatters). This is a secret: confirm with Touch ID."
                           : "Kai blocked it because \(req.whyItMatters).")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showWhy {
                VStack(alignment: .leading, spacing: 3) {
                    Text(req.resource).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                    // B2: the identities, kept apart.
                    Text("Agent: \(req.verifiedIdentity.map { "\($0), verified signature" } ?? "\(req.agent), signature not verified")")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Process: pid \(req.pid) · version \(req.pidversion)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Session: \(req.session.map { String($0.prefix(8)) } ?? "none") · tied \(req.strengthLabel == "strong" ? "by Kai's launch" : req.strengthLabel == "medium" ? "by process ancestry" : "by name only (weak)")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !req.hintTip.isEmpty {
                        Text("To avoid this, " + req.hintTip).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
            }
            // Labels are actions only: the title above names the agent and the
            // site. CardActions stacks them when they don't fit; none truncates.
            let why = (label: showWhy ? "Hide" : "Why?", toggle: { withAnimation { showWhy.toggle() } })
            switch tier {
            case 4:
                Text(AuditEvent.filesEnforcing ? "Always protected" : "Can't be allowed")
                    .font(.caption).foregroundStyle(.secondary)
                CardActions(actions: [CardAction(title: "Dismiss") { manager.deny(req) }], why: why)
            case 3:
                // The grant matches the label: the requested op, this session, 15 min.
                CardActions(actions: [CardAction(title: "Allow 15 minutes (Touch ID)", primary: true) { manager.approve(req, duration: .min10) },
                                      CardAction(title: "Keep blocked") { manager.deny(req) }], why: why)
            default:
                if req.unknownHost {
                    // B2 hostname honesty: only this connection, no rule.
                    CardActions(actions: [CardAction(title: "Allow this connection", primary: true) { manager.approveOnce(req) },
                                          CardAction(title: "Keep blocked") { manager.deny(req) }], why: why)
                } else {
                    CardActions(actions: allowActions + [CardAction(title: "Keep blocked") { manager.keepBlocked(req) }],
                                more: moreActions, why: why)
                }
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
        .confirmationDialog("Allow \(req.agentTitle) to connect to \(req.resource)?", isPresented: $showRule) {
            Button("Create rule") { manager.createRule(req) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RuleText.covers(agent: req.agentTitle, identity: req.verifiedIdentity ?? "", host: req.resource))
        }
    }

    /// "Allow this session" (when there is one), then "Allow 1 hour".
    private var allowActions: [CardAction] {
        let session = !(req.session ?? "").isEmpty
        var a: [CardAction] = []
        if session {
            a.append(CardAction(title: "Allow this session", info: InfoText.thisSession, primary: true) { ask(.session) })
        }
        if !session && req.rememberable && tier < 2 {
            // Fix 2: no session to bind to: one hour, by signed identity.
            a.append(CardAction(title: "Allow 1 hour", info: InfoText.oneHour, primary: true) { manager.allowForHour(req) })
        } else {
            a.append(CardAction(title: "Allow 1 hour", info: InfoText.oneHour, primary: !session) { ask(.hour1) })
        }
        return a
    }

    private var moreActions: [CardAction] {
        var m = (tier == 2 ? [GrantDuration.day1] : [.min10, .day1, .day7]).map { d in
            CardAction(title: "Allow \(d.label)") { ask(d) }
        }
        if req.rememberable && tier < 2 { m.append(CardAction(title: "Create a rule…") { showRule = true }) }
        return m
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

/// B1: Kai's own sounds (kai-sfx, KaiSound). "Play Kai sounds" turns them all
/// off; under it, approval needed and permission granted are on by default,
/// blocked off; each can be switched in Advanced -> App.
enum KaiSounds {
    static func play(_ cue: KaiSound.Cue, key: String, default on: Bool) {
        let all = UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true
        let enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? on
        guard all && enabled else { return }
        KaiSound.play(cue)
    }
    static func approvalNeeded() { play(.approvalNeeded, key: "soundApprovalNeeded", default: true) }
    static func permissionGranted() { play(.allowed, key: "soundPermissionGranted", default: true) }
    static func blocked() { play(.blocked, key: "soundBlocked", default: false) }
}

/// B2: a persistent decision the user made (Keep blocked, or an Allow rule).
struct DecisionRule: Decodable, Identifiable {
    let id: String
    let kind: String          // "allow" | "keep_blocked"
    let identity: String
    let agent: String
    let dest: String
    let created_utc: String
    var expires_utc: String? = nil
    var authenticated: Int? = 0
    var migrated: Int? = 0
    var created: Int { Int(created_utc) ?? 0 }
    var expires: Int { Int(expires_utc ?? "") ?? 0 }
    var isTemporary: Bool { expires > 0 }
    var hasEnded: Bool { isTemporary && expires <= Int(Date().timeIntervalSince1970) }
    var untilLabel: String {
        if (migrated ?? 0) == 1 {
            return "until " + Date(timeIntervalSince1970: TimeInterval(expires)).formatted(date: .abbreviated, time: .omitted)
                + " unless you confirm (from the old switch)"
        }
        return isTemporary ? "until " + Date(timeIntervalSince1970: TimeInterval(expires)).formatted(date: .omitted, time: .shortened)
                    : "in every session"
    }
    var isAllow: Bool { kind == "allow" }
    var agentTitle: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
}

enum RuleText {
    /// What an Allow rule covers, said before it is made and shown with it.
    static func covers(agent: String, identity: String, host: String) -> String {
        "Covers \(agent) signed as \(identity), in every session from now on, until you remove it in "
        + "Settings → Permissions. Only \(host), not its subdomains or other agents. "
        + "Kai can't tell what is sent over this encrypted connection. Needs Touch ID or your password."
    }
    /// B2: one passive hint per agent whose telemetry was blocked.
    static func telemetry(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code telemetry is blocked. To stop the attempts, set DISABLE_TELEMETRY=1."
        default:
            let t = agent.prefix(1).uppercased() + agent.dropFirst()
            return "\(t) telemetry is blocked. Kai doesn't ask about it."
        }
    }
}
