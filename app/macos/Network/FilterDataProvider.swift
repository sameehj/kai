// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's network wall. NetworkExtension hands us every new outbound flow on
// the machine; we answer as cheaply as possible:
//
//   1. Not from an agent process tree  -> allow, never look at it again.
//   2. From an agent: find the hostname (flow metadata, else the TLS SNI or
//      HTTP Host header in the first outbound bytes).
//   3. Hostname on the egress allowlist -> allow. Otherwise log it, or drop
//      it when the policy says `egress block`.
//
// All decisions come from libkai (the same engine as the hooks), so one
// policy file drives everything. This process runs as root; it reads the
// user's policy and writes to the user's audit log, whose paths the app
// passes in the filter's vendor configuration.
import Foundation
import KaiCore
import NetworkExtension
import os.log

private let log = Logger(subsystem: "io.github.sameehj.kai.network", category: "filter")

final class FilterDataProvider: NEFilterDataProvider {
    private let engine = Engine()
    private var healthTimer: DispatchSourceTimer?
    private let healthPath = "/tmp/kai-network-health.json"

    // Observed-state snapshot (U1/M0.4): a fresh file proves the network wall is
    // actually running, so `kai status`, the menu headline and session
    // enforcement labels can say "Network wall only" truthfully instead of
    // guessing. Holds no flow data.
    private func writeHealth() {
        let m = engine.mode
        let mode = m == KAI_EGRESS_BLOCK ? "block" : (m == KAI_EGRESS_LOG ? "log" : "off")
        let json = "{\"wall\":\"network\",\"mode\":\"\(mode)\",\"enforcing\":\(m == KAI_EGRESS_BLOCK),"
                 + "\"running\":true,\"ts\":\(Int(Date().timeIntervalSince1970))}"
        try? Data(json.utf8).write(to: URL(fileURLWithPath: healthPath))
    }

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        engine.configure(filterConfiguration.vendorConfiguration ?? [:])
        // Every flow comes to handleNewFlow; we decide there.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { error in
            if let error { log.error("apply settings failed: \(error.localizedDescription, privacy: .public)") }
            completionHandler(error)
        }
        writeHealth()
        // A GCD timer, not Timer.scheduledTimer: an NE provider has no run loop
        // driving a scheduled Timer, so a scheduled Timer fires once and the
        // snapshot goes stale (it then reads as "not running" and sessions were
        // mislabelled "storage only"). A dispatch timer fires on its own queue.
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.writeHealth() }
        t.resume()
        healthTimer = t
        log.info("Kai network wall started")
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        healthTimer?.cancel(); healthTimer = nil
        try? FileManager.default.removeItem(atPath: healthPath)   // goes stale -> not running
        log.info("Kai network wall stopped: \(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let sf = flow as? NEFilterSocketFlow, sf.direction == .outbound,
              let token = flow.sourceAppAuditToken else { return .allow() }
        let pid = Engine.pid(fromAuditToken: token)
        guard pid > 0, let agent = engine.agent(pid: pid, token: token) else { return .allow() }
        let pidv = Engine.pidVersion(fromAuditToken: token)

        let mode = engine.mode
        if mode == KAI_EGRESS_OFF { return .allow() }

        let (ip, port) = Engine.endpoint(sf)
        let proto = sf.socketProtocol
        // This Mac (loopback) and allowed addresses or ranges need no name.
        if engine.isAllowed(host: nil, ip: ip, port: port) { return .allow() }
        // The flow's own name can be a CDN alias (api3.cursor.sh.cdn.cloudflare.net
        // for api3.cursor.sh). Use it to allow quickly; otherwise read the name
        // the client actually asked for (TLS SNI / HTTP Host) before deciding.
        var hint: String? = nil
        if let host = sf.remoteHostname, !host.isEmpty, !Engine.isIPLiteral(host) {
            if engine.isAllowed(host: host, ip: ip, port: port) { return .allow() }
            hint = host
        }
        if proto == IPPROTO_UDP && port == "443" {
            // QUIC hides the name in an encrypted Initial. Dropping it makes the
            // client fall back to TCP, where the SNI is readable.
            return engine.decide(host: nil, agent: agent, ip: ip, port: port, what: "QUIC",
                                 pid: pid, pidv: pidv) ? .allow() : .drop()
        }
        if proto == IPPROTO_TCP && (port == "443" || port == "80") {
            engine.remember(flow, agent: agent, ip: ip, port: port, hint: hint, pid: pid, pidv: pidv)
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: 4096)
        }
        if port == "53" { return .allow() } // DNS answers are not exfiltration by themselves
        if let hint { // not web traffic, but the flow named its host
            return engine.decide(host: hint, agent: agent, ip: ip, port: port,
                                 pid: pid, pidv: pidv) ? .allow() : .drop()
        }
        // Other ports (ssh, databases, ...) with no name: only the address can
        // decide. Allow it with `egress_allow <ip>[:port]` or a range.
        return engine.decide(host: nil, agent: agent, ip: ip, port: port,
                             what: "Port \(port) connection", pid: pid, pidv: pidv)
            ? .allow() : .drop()
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        guard let ctx = engine.context(for: flow) else { return .allow() }
        let found = ctx.port == "443" ? Engine.sni(readBytes) : Engine.httpHost(readBytes)
        switch found {
        case .host(let host):
            engine.forget(flow)
            // allowed if either the requested name or the flow's name is listed
            if let h = ctx.hint, engine.isAllowed(host: h, ip: ctx.ip, port: ctx.port) { return .allow() }
            return engine.decide(host: host, agent: ctx.agent, ip: ctx.ip, port: ctx.port,
                                 pid: ctx.pid, pidv: ctx.pidv) ? .allow() : .drop()
        case .needMore where offset + readBytes.count < 16384:
            return NEFilterDataVerdict(passBytes: 0, peekBytes: offset + readBytes.count + 4096)
        default:
            engine.forget(flow)
            let what = ctx.port == "443" ? "TLS without server name" : "HTTP without Host"
            if let h = ctx.hint { // fall back to the flow's own name
                return engine.decide(host: h, agent: ctx.agent, ip: ctx.ip, port: ctx.port,
                                     pid: ctx.pid, pidv: ctx.pidv) ? .allow() : .drop()
            }
            return engine.decide(host: nil, agent: ctx.agent, ip: ctx.ip, port: ctx.port, what: what,
                                 pid: ctx.pid, pidv: ctx.pidv)
                ? .allow() : .drop()
        }
    }
}

/// Policy, caches and audit logging, shared by the provider callbacks.
final class Engine {
    enum Found { case host(String), needMore, none }
    struct FlowContext { let agent: String; let ip: String; let port: String; let hint: String?
                         let pid: pid_t; let pidv: UInt32 }

    private let lock = NSLock()
    private var policy: OpaquePointer?
    private var policyMTime: Date?
    private var policyPath = ""
    private var lastCheck = Date.distantPast
    private var agentCache: [String: String?] = [:]
    private var flows: [UUID: FlowContext] = [:]
    private var recentLogs: [String: Date] = [:]
    private var auditPath = ""
    private var owner: (uid: uid_t, gid: gid_t)?
    // M1.4: endpoint (network) grants. A denied flow to a legitimate host can be
    // approved instead of dropped; honored only with a valid HMAC-signed grant.
    private var grantStore: OpaquePointer?     // kai_approval_store*
    private var approvalKeyInstalled = false
    private var pendingSeen: [String: Date] = [:]
    private var paused = false                 // refreshed on the reload cadence

    // MARK: configuration

    /// The app passes the user's home and ids; this process runs as root.
    func configure(_ vendor: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let home = vendor["home"] as? String ?? NSHomeDirectory()
        setenv("HOME", home, 1)
        setenv("KAI_HOME", home + "/.kai", 1)
        policyPath = vendor["policy"] as? String ?? home + "/.kai/policy"
        setenv("KAI_POLICY", policyPath, 1)
        if let uid = vendor["uid"] as? Int, let gid = vendor["gid"] as? Int {
            owner = (uid_t(uid), gid_t(gid))
        }
        auditPath = String(cString: kai_audit_path())
        reloadLocked(force: true)
        // Open the endpoint-grant store (policy-only if no approval key; grants
        // then can't be honored). Lives under the user's Kai home.
        let gdir = home + "/.kai/grants"
        let key = FileManager.default.contents(atPath: home + "/.kai/approval.key") ?? Data()
        if key.count != 32 {
            grantStore = kai_approval_store_open(nil, gdir, nil, 0, 2)
        } else {
            key.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                    grantStore = kai_approval_store_open(nil, gdir, base, key.count, 2)
                }
            }
            approvalKeyInstalled = grantStore != nil
        }
    }

    var mode: kai_egress_mode {
        lock.lock(); defer { lock.unlock() }
        reloadLocked(force: false)
        return policy.map { kai_policy_egress_mode($0) } ?? KAI_EGRESS_OFF
    }

    /// Re-read the policy when the file changes (checked at most every 2 s).
    private func reloadLocked(force: Bool) {
        if !force && Date().timeIntervalSince(lastCheck) < 2 { return }
        lastCheck = Date()
        // The first approval can create the key after this filter starts.
        // Install it on the existing store so the next flow can use the grant.
        if let gs = grantStore, !approvalKeyInstalled {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            if let key = FileManager.default.contents(atPath: home + "/.kai/approval.key"), key.count == 32 {
                approvalKeyInstalled = key.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                    return kai_approval_store_install_key(gs, base, key.count) == 1
                }
            }
        }
        paused = kai_wall_paused("network", Int64(Date().timeIntervalSince1970)) != 0
        let mtime = (try? FileManager.default.attributesOfItem(atPath: policyPath))?[.modificationDate] as? Date
        if !force && mtime == policyMTime && policy != nil { return }
        var err = [CChar](repeating: 0, count: 256)
        guard let p = kai_policy_load(nil, &err, err.count) else {
            // Keep the last good policy; a typo must not switch the wall off.
            log.error("policy error: \(String(cString: err), privacy: .public)")
            return
        }
        if let old = policy { kai_policy_free(old) }
        policy = p
        policyMTime = mtime
        agentCache.removeAll()
        log.info("policy loaded from \(self.policyPath, privacy: .public)")
    }

    // MARK: who is this

    static func pid(fromAuditToken data: Data) -> pid_t {
        guard data.count == MemoryLayout<audit_token_t>.size else { return 0 }
        let token = data.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        return pid_t(bitPattern: token.val.5) // audit_token_to_pid()
    }

    static func pidVersion(fromAuditToken data: Data) -> UInt32 {
        guard data.count == MemoryLayout<audit_token_t>.size else { return 0 }
        return data.withUnsafeBytes { $0.load(as: audit_token_t.self) }.val.7
    }

    /// Agent name if pid is an agent or runs under one. Cached per process
    /// instance (pid + pidversion), so pid reuse can't confuse it.
    func agent(pid: pid_t, token: Data) -> String? {
        let key = "\(pid):\(Engine.pidVersion(fromAuditToken: token))"
        lock.lock(); defer { lock.unlock() }
        reloadLocked(force: false)
        if let cached = agentCache[key] { return cached }
        guard let p = policy else { return nil }
        var name = [CChar](repeating: 0, count: 64)
        var apid: Int32 = 0
        let hit = kai_process_agent(p, pid, &name, name.count, &apid) == 1
        let result: String? = hit ? String(cString: name) : nil
        if agentCache.count > 8192 { agentCache.removeAll() }
        agentCache[key] = result
        return result
    }

    // MARK: flows waiting for their first bytes

    func remember(_ flow: NEFilterFlow, agent: String, ip: String, port: String, hint: String?,
                  pid: pid_t, pidv: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if flows.count > 4096 { flows.removeAll() }
        flows[flow.identifier] = FlowContext(agent: agent, ip: ip, port: port, hint: hint,
                                             pid: pid, pidv: pidv)
    }

    /// Is this connection on the allowlist? (No logging: used for fast paths.)
    func isAllowed(host: String?, ip: String, port: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        reloadLocked(force: false)
        guard let p = policy else { return true }
        var why = [CChar](repeating: 0, count: 256)
        return kai_egress_endpoint_allowed(p, host, ip, Int32(port) ?? 0, &why, why.count) == 1
    }

    func context(for flow: NEFilterFlow) -> FlowContext? {
        lock.lock(); defer { lock.unlock() }
        return flows[flow.identifier]
    }

    func forget(_ flow: NEFilterFlow) {
        lock.lock(); defer { lock.unlock() }
        flows[flow.identifier] = nil
    }

    // MARK: the decision

    /// true = allow. host nil means we could not learn a hostname.
    func decide(host: String?, agent: String, ip: String, port: String, what: String? = nil,
                pid: pid_t = 0, pidv: UInt32 = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = policy else { return true }
        let mode = kai_policy_egress_mode(p)
        if mode == KAI_EGRESS_OFF { return true }
        if paused { return true }   // wall paused (time-boxed, auto-resume): allow
        var why = [CChar](repeating: 0, count: 256)
        if kai_egress_endpoint_allowed(p, host, ip, Int32(port) ?? 0, &why, why.count) == 1 { return true }
        let target = host ?? "\(ip):\(port)"
        // M1.4: a valid human-approved endpoint grant allows this destination.
        if endpointGrantAllows(pid: pid, pidv: pidv, agent: agent, dest: target) {
            kai_grant_audit("used", "(granted)", agent, target, Int32(KAI_OP_CONNECT.rawValue),
                            "allow", "scoped egress grant")
            return true
        }
        let block = mode == KAI_EGRESS_BLOCK
        let detail = host == nil
            ? "\(what ?? "connection") to \(ip):\(port), host unknown"
            : "connection to \(host!) (\(ip):\(port)) is not on the allowlist"
        auditLocked(agent: agent, decision: block ? "block" : "log", target: target, detail: detail)
        if block { requestEgressApproval(pid: pid, pidv: pidv, agent: agent, dest: target) }
        return !block
    }

    /// Does a valid endpoint grant authorize this agent process to reach `dest`?
    private func endpointGrantAllows(pid: pid_t, pidv: UInt32, agent: String, dest: String) -> Bool {
        guard let gs = grantStore, pid > 0 else { return false }
        _ = kai_approval_store_reload(gs, 0)      // debounced; picks up new/revoked grants
        // Resolve the session the storage extension minted for this process tree
        // (shared via ~/.kai/sessions/<pid>.json), so a session-scoped grant made
        // for the agent covers the child (ssh/node) that opens the connection.
        let s = sessionFor(pid: pid, pidv: pidv)
        var ok = false
        agent.withCString { ap in s.sid.withCString { sp in s.project.withCString { pp in
            var subj = kai_grant_subject(pid: Int32(pid), pidversion: UInt64(pidv),
                                         agent: ap, strength: 1 /* medium */,
                                         session_id: sp, project: pp)
            var why = [CChar](repeating: 0, count: 256)
            ok = kai_approval_store_decide(gs, dest, nil, Int32(KAI_OP_CONNECT.rawValue), &subj,
                                           Int64(Date().timeIntervalSince1970), &why, why.count) == 1
        }}}
        return ok
    }

    /// The session (and project) the storage extension recorded for this process
    /// instance, or empty if none / pidversion mismatch (reused pid).
    private func sessionFor(pid: pid_t, pidv: UInt32) -> (sid: String, project: String) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard let data = FileManager.default.contents(atPath: home + "/.kai/sessions/\(pid).json"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fv = (o["pidversion"] as? NSNumber)?.uint32Value, fv == pidv
        else { return ("", "") }
        return (o["session"] as? String ?? "", o["project"] as? String ?? "")
    }

    /// Stage an async approval request for a blocked destination (deduped), so
    /// the user can approve it instead of the agent only seeing a dead socket.
    private func requestEgressApproval(pid: pid_t, pidv: UInt32, agent: String, dest: String) {
        let key = "\(pid):\(dest)"
        if let last = pendingSeen[key], Date().timeIntervalSince(last) < 600 { return }
        if pendingSeen.count > 4096 { pendingSeen.removeAll() }
        pendingSeen[key] = Date()
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.kai/pending"
        mkdir(dir, 0o700)
        let id = "net-\(pid)-\(pidv)-\(Int(Date().timeIntervalSince1970))"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let json = "{\"id\":\"\(id)\",\"agent\":\"\(esc(agent))\",\"pid\":\(pid)," +
                   "\"pidversion\":\(pidv),\"strength\":1,\"resource\":\"\(esc(dest))\"," +
                   "\"op\":\"connect\",\"ts\":\(Int(Date().timeIntervalSince1970))}"
        let fp = dir + "/" + id + ".json"
        let fd = open(fp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        if fd >= 0 { fchmod(fd, 0o644); let b = Array(json.utf8)
                     b.withUnsafeBytes { if let base = $0.baseAddress { _ = write(fd, base, b.count) } }
                     close(fd) }
        if let o = owner { chown(fp, o.uid, o.gid); chown(dir, o.uid, o.gid) }
        kai_grant_audit("requested", id, agent, dest, Int32(KAI_OP_CONNECT.rawValue),
                        "request", "egress awaiting approval")
    }

    /// One audit record per agent+target+decision every 10 minutes, so a
    /// chatty tool can't flood the log.
    private func auditLocked(agent: String, decision: String, target: String, detail: String) {
        let key = "\(agent)|\(decision)|\(target)"
        if let last = recentLogs[key], Date().timeIntervalSince(last) < 600 { return }
        if recentLogs.count > 4096 { recentLogs.removeAll() }
        recentLogs[key] = Date()
        // Structured denial: reason code "not_on_allowlist" goes in `rule`, the
        // destination in `target`. Fixes the record that read "rule: <host>" as
        // if a rule matched -- no rule matched; the host was absent from the list.
        kai_denial_audit("network", agent, decision, target, "connect",
                         KAI_REASON_NOT_ALLOWLISTED, nil, detail)
        // We run as root: keep the user's audit log owned by the user.
        if let o = owner, !auditPath.isEmpty {
            chown(auditPath, o.uid, o.gid)
            chown((auditPath as NSString).deletingLastPathComponent, o.uid, o.gid)
        }
        log.info("\(decision, privacy: .public) \(agent, privacy: .public) -> \(target, privacy: .public)")
    }

    // MARK: parsing helpers

    /// (address, port). IPv6 addresses come back in brackets so that
    /// "\(ip):\(port)" reads as [2606:4700::1]:443, not 2606:4700::1:443.
    static func endpoint(_ f: NEFilterSocketFlow) -> (String, String) {
        guard let e = f.remoteEndpoint as? NWHostEndpoint else { return ("?", "?") }
        return (e.hostname.contains(":") ? "[\(e.hostname)]" : e.hostname, e.port)
    }

    static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    static func sni(_ data: Data) -> Found {
        var host = [CChar](repeating: 0, count: 256)
        let rc = data.withUnsafeBytes { raw -> Int32 in
            kai_tls_sni(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &host, host.count)
        }
        switch rc {
        case 1: return .host(String(cString: host))
        case -1: return .needMore
        default: return .none
        }
    }

    static func httpHost(_ data: Data) -> Found {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let headEnd = text.range(of: "\r\n\r\n") else { return data.count < 4096 ? .needMore : .none }
        for line in text[..<headEnd.lowerBound].split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "host" {
                var h = parts[1].trimmingCharacters(in: .whitespaces)
                if let colon = h.lastIndex(of: ":"), !h.contains("]") { h = String(h[..<colon]) }
                return h.isEmpty ? .none : .host(h.lowercased())
            }
        }
        return .none
    }
}
