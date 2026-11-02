// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Nov 1 corrective change, step 5: one story on every permission screen.
// Icons and tones from what happened (an allow is never a warning), the
// triggering command only when it is one, one row per agent and target for
// grant records, Recent without blocks of hosts allowed since, and grant scope
// and duration in the same words. Foundation only, so tests/app/activity_main
// compiles it with AuditLog.swift.
import Foundation

enum EventTone { case stopped, allowed, neutral, cleaned, warning }

extension AuditEvent {
    var tone: EventTone {
        if isGrant {
            switch event {
            case "approved", "used": return .allowed
            case "denied": return .stopped
            default: return .neutral
            }
        }
        switch decision {
        case "block", "ask": return .stopped
        case "allow", "exempt": return .allowed
        case "redact", "replace": return .cleaned
        case "log", "note": return .neutral
        default: return .warning
        }
    }

    var iconName: String {
        switch tone {
        case .stopped: return "hand.raised.fill"
        case .allowed: return "checkmark.circle.fill"
        case .cleaned: return "wand.and.stars"
        case .neutral: return decision == "log" ? "eye" : "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    /// Nov 2: an event from a temporary test folder (Kai's own or a live check's
    /// test run) that reached the real log: labelled "test" in Activity.
    var isTest: Bool {
        let c = cwd ?? ""
        return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { c.hasPrefix($0) }
    }

    /// The verb Activity shows, with "· test" for a test event.
    var verbLabel: String { isTest ? "\(verb) · test" : verb }

    /// The triggering command, only for a shell tool (a path or a host isn't one).
    var whileRunning: String? {
        guard !isNetwork, !isStorage, !isGrant, let t = target, !t.isEmpty else { return nil }
        switch tool ?? "" {
        case "Bash", "Shell", "shell", "run_terminal_cmd", "exec_command": return t
        default: return nil
        }
    }

    /// Grant records merge per agent, kind and target; others keep their detail.
    var mergeKey: String {
        if isGrant { return "grant|\(event)|\(agentKey)|\((target ?? "").lowercased())" }
        return "\(agentName)|\(decision)|\(rule)|\(excerpt ?? "")|\(detail)"
    }

    /// Recent (newest first): a block of a host that was allowed afterwards drops out.
    static func droppingAllowedBlocks(_ events: [AuditEvent]) -> [AuditEvent] {
        var allowedSince = Set<String>()
        var out: [AuditEvent] = []
        for e in events {
            let host = (e.target ?? "").lowercased()
            if e.isGrant && (e.event == "approved" || e.event == "used") { allowedSince.insert(e.agentKey + "|" + host) }
            if e.isBlock && e.isNetwork && allowedSince.contains(e.agentKey + "|" + host) { continue }
            out.append(e)
        }
        return out
    }
}

/// A grant's scope and how long it lasts, in the same words everywhere.
enum GrantText {
    static func scope(scope: Int, session: Bool, created: Int, expires: Int) -> String {
        if scope == 1 { return "once" }
        if session { return "this session" }
        return "for " + duration(expires - created)
    }

    static func status(session: Bool, expires: Int, now: Int = Int(Date().timeIntervalSince1970)) -> String {
        let secs = expires - now
        if secs <= 0 { return "ended" }
        if session { return "until the session ends" }
        if secs < 3600 { return "\(max(1, secs / 60))m left" }
        if secs < 86_400 { return "\(secs / 3600)h \((secs % 3600) / 60)m left" }
        return "\(secs / 86_400)d \((secs % 86_400) / 3600)h left"
    }

    static func duration(_ secs: Int) -> String {
        switch secs {
        case ..<60: return "\(max(secs, 0)) seconds"
        case ..<3600: return "\(secs / 60) min"
        case 3600: return "1 hour"
        case ..<86_400: return "\(Int((Double(secs) / 3600).rounded())) hours"
        case 86_400: return "1 day"
        default: return "\(Int((Double(secs) / 86_400).rounded())) days"
        }
    }
}
