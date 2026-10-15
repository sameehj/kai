// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Numbers and lists the redesigned screens show, all derived from the audit
// log events the app already follows. Nothing here is stored separately.
import Foundation

/// One destination an agent connected to that is not on the allowlist.
struct ReachedHost: Identifiable, Equatable {
    let host: String
    var agents: Set<String>
    var count: Int
    var blocked: Bool
    var last: Date?
    var id: String { host }
    var agentList: String { agents.sorted().joined(separator: ", ") }
}

extension AppModel {
    private var weekEvents: [AuditEvent] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return events.filter { ($0.date ?? .distantPast) >= cutoff }
    }

    /// Actions stopped in the last 7 days (hooks, gateway and network wall).
    var blockedThisWeek: Int { weekEvents.filter(\.isBlock).count }

    /// Prompts or requests Kai cleaned (redacted / replaced) in the last 7 days.
    var cleanedThisWeek: Int {
        weekEvents.filter { $0.decision == "redact" || $0.decision == "replace" }.count
    }

    /// Hosts the network wall recorded, most recent first.
    var reachedHosts: [ReachedHost] {
        var byHost: [String: ReachedHost] = [:]
        for e in events where e.source == "network" && !e.rule.isEmpty {
            var h = byHost[e.rule] ?? ReachedHost(host: e.rule, agents: [], count: 0, blocked: false, last: nil)
            h.agents.insert(e.agentName)
            h.count += 1
            h.blocked = h.blocked || e.isBlock
            if let d = e.date, d > (h.last ?? .distantPast) { h.last = d }
            byHost[e.rule] = h
        }
        let allowed = Set(policy?.egressAllow ?? [])
        return byHost.values
            .filter { !allowed.contains($0.host) }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    /// Hook, gateway and block events, the ones worth a line in the menu.
    var importantEvents: [AuditEvent] {
        events.filter { $0.source != "network" || $0.isBlock }
    }

    /// The block that is still "fresh" (last 30 s), shown as the alert hero.
    var freshBlock: AuditEvent? {
        guard let t = lastBlockAt, Date().timeIntervalSince(t) < 30 else { return nil }
        return events.first(where: \.isBlock)
    }

    /// Allow a host the wall noticed: an IP:port can't be allowed by name.
    func allowHost(_ host: String) {
        guard !host.contains(":"), !host.hasPrefix("[") else {
            errorMessage = "Only host names can be allowed; \(host) has no name yet."
            return
        }
        add("egress_allow", host)
    }
}
