// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import Foundation

/// One record of ~/.kai/audit.log. The log never holds secret values, only
/// rule names and short reasons, so it is safe to show.
struct AuditEvent: Decodable, Identifiable, Equatable {
    let ts: String
    let source: String
    let event: String
    let decision: String
    let rule: String
    let detail: String
    let h: String

    var id: String { h }
    var date: Date? { AuditEvent.iso.date(from: ts) }
    var isBlock: Bool { decision == "block" }
    var isNotable: Bool { decision != "allow" }

    /// Network and gateway records name the agent in `event`.
    var agentName: String {
        let who = (source == "network" || source == "gateway") ? event : source
        switch who {
        case "claude": return "Claude Code"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        case "anthropic", "openai", "openrouter": return "AI gateway (\(who))"
        default: return who.capitalized
        }
    }

    /// One readable line, e.g. "Blocked Claude Code: reading protected path (~/.ssh)".
    var summary: String {
        let verb = isBlock ? "Blocked" : (decision == "log" ? "Noticed" : "Warning")
        let what = detail.isEmpty ? (rule.isEmpty ? event : rule) : detail
        return "\(verb) \(agentName): \(what)"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Follows the audit log by polling its size. New notable records are handed
/// to `onNew`; the first read only fills history, so old events never notify.
final class AuditTail {
    private let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var recent: [AuditEvent] = []
    private let keep = 200

    init(path: String) { url = URL(fileURLWithPath: path) }

    /// Returns the notable events that appeared since the last call.
    func poll() -> [AuditEvent] {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            offset = 0
            return []
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data(); recent = [] } // rotated or truncated
        if size == offset { return [] }

        let firstRead = offset == 0
        // On the first read only look at the tail; the log can be large.
        let start = firstRead && size > 512_000 ? size - 512_000 : offset
        try? fh.seek(toOffset: start)
        var data = partial + ((try? fh.readToEnd()) ?? Data())
        offset = size

        // Keep an incomplete last line for next time.
        if let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) {
            partial = data[(lastNL + 1)...]
            data = data[..<lastNL]
        } else {
            partial = data
            return []
        }

        let decoder = JSONDecoder()
        var fresh: [AuditEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let e = try? decoder.decode(AuditEvent.self, from: line), e.isNotable {
                fresh.append(e)
            }
        }
        recent = Array((fresh.reversed() + recent).prefix(keep))
        return firstRead ? [] : fresh
    }
}
