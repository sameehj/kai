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

    /// What deserves a line in the menu: things Kai stopped or cleaned.
    /// Prompt-injection suspicions and noticed hosts are signals, not
    /// incidents; they stay on the Activity page.
    var importantEvents: [AuditEvent] {
        events.filter { ($0.isBlock || $0.decision == "redact" || $0.decision == "replace") && !$0.isSilent && !$0.isGrant }
    }

    /// Identical incidents collapsed with a count, for the menu's Recent list.
    var importantEventGroups: [EventGroup] {
        var order: [String] = []
        var map: [String: [AuditEvent]] = [:]
        for e in importantEvents {
            let key = "\(e.agentName)|\(e.rule)|\(e.target ?? "")|\(e.decision)"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { k in EventGroup(event: map[k]!.first!, count: map[k]!.count) }
    }

    /// Prompt-injection suspicions in the last 7 days (shown in Activity).
    var suspicionsThisWeek: Int {
        events.filter { $0.detail.hasPrefix("possible prompt injection") }.count
    }

    /// A hook block that is still "fresh" (last 30 s), shown as a notice card.
    /// Wall blocks (storage, network) are left out: each stages its own
    /// decision card in Needs you, so showing them here would double up.
    /// Batch 2: the popover's value line, from meaningful events today only
    /// (telemetry, remembered blocks and the QUIC fallback never count).
    var valueLine: String {
        let today = events.filter { e in e.date.map { Calendar.current.isDateInToday($0) } ?? false }
        let secrets = today.filter(\.isSecretKept).count
        let other = today.filter { $0.isBlock && !$0.isSilent && !$0.isGrant && !$0.isSecretKept }.count
        var parts: [String] = []
        if secrets > 0 { parts.append("kept \(secrets) secret\(secrets == 1 ? "" : "s") private") }
        if other > 0 { parts.append("stopped \(other) risky action\(other == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing risky today" : "Kai " + parts.joined(separator: " and ") + " today"
    }

    var freshBlock: AuditEvent? {
        guard let t = lastBlockAt, Date().timeIntervalSince(t) < 30 else { return nil }
        return events.first {
            $0.isBlock && !$0.isStorage && !$0.isNetwork &&
                ($0.date.map { Date().timeIntervalSince($0) < 30 } ?? false)
        }
    }

    /// Allow a destination the wall noticed: a host name, or for a connection
    /// with no name the exact address and port (e.g. 203.0.113.5:22).
    func allowHost(_ host: String) {
        add("egress_allow", host)
    }
}
