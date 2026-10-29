// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Numbers and lists the redesigned screens show, all derived from the audit
// log events the app already follows. Nothing here is stored separately.
import Foundation
import KaiCore

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
        ReachedHost.group(events, allowed: Set(policy?.egressAllow ?? []))
    }

    /// Spec §2: Activity's weekly line, from the per-day counters (last 7 days).
    var weeklyLine: String {
        var secrets = 0, blocked = 0, paused = 0
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for d in 0..<7 {
            let day = f.string(from: Date().addingTimeInterval(-Double(d) * 86400))
            secrets += Int(kai_daily_count(day, CChar(UInt8(ascii: "s")))) + Int(kai_daily_count(day, CChar(UInt8(ascii: "c"))))
            blocked += Int(kai_daily_count(day, CChar(UInt8(ascii: "b"))))
            paused += Int(kai_daily_count(day, CChar(UInt8(ascii: "p"))))
        }
        return "This week: \(secrets) secret\(secrets == 1 ? "" : "s") kept private, \(blocked) risky action"
            + "\(blocked == 1 ? "" : "s") stopped, \(paused) time\(paused == 1 ? "" : "s") you had to pause Kai."
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
        // Fix 1: from the per-day counter written with each audit record, not
        // the 300-event buffer this app keeps for display.
        var s: Int32 = 0, b: Int32 = 0
        kai_daily_counts(nil, &s, &b)
        let secrets = Int(s), other = Int(b)
        // "Kai kept N secrets private and stopped M actions" (no "risky").
        var parts: [String] = []
        if secrets > 0 { parts.append("kept \(secrets) secret\(secrets == 1 ? "" : "s") private") }
        if other > 0 { parts.append("stopped \(other) action\(other == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing stopped today" : "Kai " + parts.joined(separator: " and ") + " today"
    }

    /// Today's most repeated stopped item, when it repeated (exact, from the log).
    var topToday: (item: String, count: Int)? {
        var buf = [CChar](repeating: 0, count: 256)
        var n: Int32 = 0
        guard kai_daily_top(&buf, buf.count, &n) == 1, n >= 2 else { return nil }
        return (String(cString: buf), Int(n))
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
