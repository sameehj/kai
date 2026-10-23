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

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        engine.configure(filterConfiguration.vendorConfiguration ?? [:])
        // Every flow comes to handleNewFlow; we decide there.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { error in
            if let error { log.error("apply settings failed: \(error.localizedDescription, privacy: .public)") }
            completionHandler(error)
        }
        log.info("Kai network wall started")
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Kai network wall stopped: \(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let sf = flow as? NEFilterSocketFlow, sf.direction == .outbound,
              let token = flow.sourceAppAuditToken else { return .allow() }
        let pid = Engine.pid(fromAuditToken: token)
        guard pid > 0, let agent = engine.agent(pid: pid, token: token) else { return .allow() }

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
            return engine.decide(host: nil, agent: agent, ip: ip, port: port, what: "QUIC") ? .allow() : .drop()
        }
        if proto == IPPROTO_TCP && (port == "443" || port == "80") {
            engine.remember(flow, agent: agent, ip: ip, port: port, hint: hint)
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0,
                                      filterOutbound: true, peekOutboundBytes: 4096)
        }
        if port == "53" { return .allow() } // DNS answers are not exfiltration by themselves
        if let hint { // not web traffic, but the flow named its host
            return engine.decide(host: hint, agent: agent, ip: ip, port: port) ? .allow() : .drop()
        }
        // Other ports (ssh, databases, ...) with no name: only the address can
        // decide. Allow it with `egress_allow <ip>[:port]` or a range.
        return engine.decide(host: nil, agent: agent, ip: ip, port: port,
                             what: "Port \(port) connection")
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
            return engine.decide(host: host, agent: ctx.agent, ip: ctx.ip, port: ctx.port) ? .allow() : .drop()
        case .needMore where offset + readBytes.count < 16384:
            return NEFilterDataVerdict(passBytes: 0, peekBytes: offset + readBytes.count + 4096)
        default:
            engine.forget(flow)
            let what = ctx.port == "443" ? "TLS without server name" : "HTTP without Host"
            if let h = ctx.hint { // fall back to the flow's own name
                return engine.decide(host: h, agent: ctx.agent, ip: ctx.ip, port: ctx.port) ? .allow() : .drop()
            }
            return engine.decide(host: nil, agent: ctx.agent, ip: ctx.ip, port: ctx.port, what: what)
                ? .allow() : .drop()
        }
    }
}

/// Policy, caches and audit logging, shared by the provider callbacks.
final class Engine {
    enum Found { case host(String), needMore, none }
    struct FlowContext { let agent: String; let ip: String; let port: String; let hint: String? }

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

    private static func pidVersion(fromAuditToken data: Data) -> UInt32 {
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

    func remember(_ flow: NEFilterFlow, agent: String, ip: String, port: String, hint: String?) {
        lock.lock(); defer { lock.unlock() }
        if flows.count > 4096 { flows.removeAll() }
        flows[flow.identifier] = FlowContext(agent: agent, ip: ip, port: port, hint: hint)
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
    func decide(host: String?, agent: String, ip: String, port: String, what: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = policy else { return true }
        let mode = kai_policy_egress_mode(p)
        if mode == KAI_EGRESS_OFF { return true }
        var why = [CChar](repeating: 0, count: 256)
        if kai_egress_endpoint_allowed(p, host, ip, Int32(port) ?? 0, &why, why.count) == 1 { return true }
        let target = host ?? "\(ip):\(port)"
        let block = mode == KAI_EGRESS_BLOCK
        let detail = host == nil
            ? "\(what ?? "connection") to \(ip):\(port), host unknown"
            : "connection to \(host!) (\(ip):\(port)) is not on the allowlist"
        auditLocked(agent: agent, decision: block ? "block" : "log", target: target, detail: detail)
        return !block
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
