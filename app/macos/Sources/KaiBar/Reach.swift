// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Where agents tried to go, one row per destination. Foundation only, so
// tests/app/run_app_tests.sh can compile it without the app.
import Foundation

struct ReachedHost: Identifiable, Equatable {
    let host: String
    var agents: Set<String>
    var count: Int
    var blocked: Bool
    var last: Date?
    var latest: AuditEvent?
    var id: String { host }
    var agentList: String { agents.sorted().joined(separator: ", ") }

    /// Spec §4: group network records by their destination (`target`), never by
    /// `rule`, which holds a reason code such as not_on_allowlist. Silent records
    /// (telemetry, kept blocked, the QUIC fallback) and grant bookkeeping are left
    /// out; destinations you already allowed drop out.
    static func group(_ events: [AuditEvent], allowed: Set<String>) -> [ReachedHost] {
        var by: [String: ReachedHost] = [:]
        for e in events where e.source == "network" && !e.isSilent {
            guard let t = e.target, !t.isEmpty else { continue }
            var h = by[t] ?? ReachedHost(host: t, agents: [], count: 0, blocked: false, last: nil, latest: nil)
            h.agents.insert(e.agentName)
            h.count += 1
            h.blocked = h.blocked || e.isBlock
            if let d = e.date, d > (h.last ?? .distantPast) { h.last = d; h.latest = e }
            if h.latest == nil { h.latest = e }
            by[t] = h
        }
        return by.values.filter { !allowed.contains($0.host) }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }
}
