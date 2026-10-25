// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import Foundation

/// One record of ~/.kai/audit.log. The log never holds secret values: rule
/// names, short reasons and, for decisions, an excerpt of what was blocked
/// with every rule match already hidden by the scanner.
/// Identical incidents collapsed with a count, for the menu's Recent list.
struct EventGroup: Identifiable {
    let event: AuditEvent
    let count: Int
    var id: String { event.id }
}

struct AuditEvent: Decodable, Identifiable, Equatable {
    let ts: String
    let source: String
    let event: String
    let decision: String
    let rule: String
    let detail: String
    let h: String
    // Context, on records written since Kai 0.1 "activity" (absent on older ones)
    let tool: String?
    let target: String?
    let match: String?
    let session: String?
    let cwd: String?

    var id: String { h }
    var date: Date? { AuditEvent.iso.date(from: ts) }
    var isBlock: Bool { decision == "block" }
    /// "After the block, the agent ..." follow-ups belong to their block.
    var isNote: Bool { decision == "note" }
    var isExempt: Bool { decision == "exempt" }
    var isNotable: Bool { decision != "allow" }
    var isNetwork: Bool { source == "network" || source == "gateway" }
    var isStorage: Bool { source == "storage" }
    var isPrompt: Bool { event == "UserPromptSubmit" || event == "beforeSubmitPrompt" }

    /// Network, gateway and storage records name the agent in `event`; hook
    /// records put it in `source`.
    var agentName: String {
        let who = (isNetwork || isStorage) ? event : source
        switch who {
        case "claude": return "Claude Code"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        case "anthropic", "openai", "openrouter": return "AI gateway (\(who))"
        default: return who.capitalized
        }
    }

    /// What kind of action it was, in words.
    var actionLabel: String? {
        if isPrompt { return "Prompt" }
        if isNetwork { return "Connection" }
        if isStorage { return "Protected file (storage wall)" }
        switch tool ?? "" {
        case "Bash", "Shell", "shell": return "Command"
        case "Read": return "File read"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "File edit"
        case "Grep", "Glob", "LS": return "File search"
        case "": return nil
        case let t where t.hasPrefix("mcp__") || t == "MCP": return "Tool call"
        case let t: return t
        }
    }

    var verb: String {
        switch decision {
        case "block": return "Blocked"
        case "log": return "Noticed"
        case "exempt": return "Allowed by your exception"
        case "ask": return "Asked you"
        case "redact", "replace": return "Cleaned"
        default: return "Warning"
        }
    }

    /// One readable line, e.g. "Blocked Claude Code: reading protected path (~/.ssh)".
    var summary: String {
        let what = detail.isEmpty ? (rule.isEmpty ? event : rule) : detail
        return "\(verb) \(agentName): \(what)"
    }

    /// The record's excerpt, if Kai kept one.
    var excerpt: String? { (target?.isEmpty ?? true) ? nil : target }

    // MARK: "Not a threat"

    /// Kai's own protection (its files, the agents' hook settings): never
    /// exempted. Mirrors kai_rule_is_builtin in src/scan.c.
    var isBuiltinRule: Bool {
        let builtin = ["kai_self_protect", "~/.kai", ".claude/settings.json", ".claude/settings.local.json",
                       ".cursor/hooks.json", ".codex/hooks.json", ".codex/config.toml",
                       "NativeMessagingHosts/io.github.sameehj.kai.json", "hooks.json", "config.toml"]
        return builtin.contains { rule == $0 || rule.hasSuffix($0) }
    }

    private var isShell: Bool { ["Bash", "Shell", "shell"].contains(tool ?? "") }
    private var isFileTool: Bool {
        ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "Grep", "Glob", "LS"].contains(tool ?? "")
    }

    /// An exception for this exact command is possible: a shell command
    /// blocked by an upload or protected-path rule.
    var canExemptCommand: Bool {
        (isBlock || decision == "warn" || decision == "ask") && isShell && excerpt != nil && !rule.isEmpty && !isBuiltinRule
    }

    /// The glob `kai policy add exempt` gets: the command as recorded, with
    /// hidden parts and cut-off ends as wildcards, so it matches the real
    /// command and little else.
    var exemptPattern: String? {
        guard var t = excerpt else { return nil }
        var head = "", tail = ""
        if t.hasPrefix("…") { t.removeFirst(); head = "*" }
        if t.hasSuffix("…") { t.removeLast(); tail = "*" }
        let ns = t as NSString
        var out = "", last = 0
        for m in AuditEvent.redacted.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += AuditEvent.globEscape(ns.substring(with: NSRange(location: last, length: m.range.location - last))) + "*"
            last = m.range.location + m.range.length
        }
        return head + out + AuditEvent.globEscape(ns.substring(from: last)) + tail
    }

    /// The file a file-tool block was about, as a policy path (absolute,
    /// ~ for home), for an "allow" exception. nil when that isn't possible.
    var allowablePath: String? {
        guard isBlock || decision == "ask", isFileTool, !isBuiltinRule, var p = excerpt,
              !p.contains("REDACTED") else { return nil }
        if !p.hasPrefix("/") && !p.hasPrefix("~") {
            guard let cwd, !cwd.isEmpty else { return nil }
            p = (cwd as NSString).appendingPathComponent(p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        return p.contains(" ") || p.contains("#") ? nil : p
    }

    /// What the scanner put where a secret was: a wildcard in an exception.
    private static let redacted = try! NSRegularExpression(pattern: #"\[REDACTED by Kai: [^\]]*\]"#)

    /// Literal text for fnmatch. A policy line can't hold '#' or a line
    /// break, so those become '?' (any one character).
    private static func globEscape(_ s: String) -> String {
        var r = ""
        for c in s {
            switch c {
            case "*", "?", "[", "\\": r += "\\\(c)"
            case "\n", "\r", "#": r += "?"
            default: r.append(c)
            }
        }
        return r
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
    private let keep = 300

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
