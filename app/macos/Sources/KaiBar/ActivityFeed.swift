// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.4 Activity: one grouped list of what Kai recorded in a workspace today,
// built from `kai activity --json` (the opt-in recorder), Kai's decisions
// (the audit log) and, when Internet watching is on, observed connections.
//
// Copy rules (docs/kai-ux-decisions-2026-11-19): a hook sees a REQUEST before
// the tool runs, so recorded tool calls are "Requested", never "done"; a stop
// is "Stopped"; a connection is "Observed". No matching record never means
// it didn't happen.
//
// Foundation only: compiled into the app tests with AuditLog.swift.
import Foundation

/// `kai activity --json`.
struct ActivityGroups: Decodable, Equatable {
    struct Item: Decodable, Equatable { var name: String; var count: Int }
    struct Group: Decodable, Equatable {
        var agent: String
        var op: String
        var count: Int
        var distinct: Int = 0
        var sessions: Int = 0
        var stops: Int = 0
        var first: Double = 0
        var last: Double = 0
        var items: [Item] = []
    }
    var recording: Bool = false
    var groups: [Group] = []
    var total: Int = 0
    /// 0.5: per Kai session (Now cards, the timeline); nil from older CLIs.
    var sessions: [SessionActivity]? = nil
    /// 0.5: the oldest record read (when recording began, within the window).
    var first_record: Double? = nil
    /// 0.5.1: records since local midnight (the popover's "Today: N actions").
    var today: Int? = nil

    static func parse(_ json: String) -> ActivityGroups? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActivityGroups.self, from: d)
    }
}

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", connections = "Connections", stops = "Stops"
    var id: String { rawValue }
}

struct ActivityItem: Identifiable, Equatable {
    enum Kind: String { case read, edit, write, command, mcp, tool, connection, stop }
    var id: String
    var kind: Kind
    var agentKey: String
    var agent: String
    var title: String
    var detail: String
    var count: Int
    var countText: String
    var outcome: String
    var source: String
    var session: String
    var scope: String
    var examples: [String]
    var explanation: String
    /// Stops: the decision id the agent was given, when there is one.
    var decisionID: String? = nil
    /// Stops: the audit record's hash (AuditEvent.id).
    var eventID: String? = nil

    var letter: String {
        switch kind {
        case .read: return "R"
        case .edit, .write: return "F"
        case .command: return "C"
        case .mcp, .tool: return "T"
        case .connection: return "N"
        case .stop: return "!"
        }
    }
    var symbol: String {
        switch kind {
        case .read: return "doc.text.magnifyingglass"
        case .edit, .write: return "doc.badge.ellipsis"
        case .command: return "terminal"
        case .mcp, .tool: return "wrench.and.screwdriver"
        case .connection: return "network"
        case .stop: return "hand.raised"
        }
    }
    func matches(_ f: ActivityFilter) -> Bool {
        switch f {
        case .all: return true
        case .files: return [.read, .edit, .write].contains(kind)
        case .connections: return kind == .connection
        case .stops: return kind == .stop
        }
    }
    func matches(search q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return ([title, detail, agent, agentKey] + examples).contains { $0.lowercased().contains(q) }
    }
}

enum ActivityFeed {
    static func agentTitle(_ key: String) -> String {
        switch key {
        case "claude": return "Claude Code"
        case "cursor": return "Cursor"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        default: return key.isEmpty ? "Unknown agent" : key.capitalized
        }
    }

    /// What each agent's hooks report, stated once (Agents rows, Ask Kai).
    static func coverage(_ key: String) -> String {
        switch key {
        case "claude": return "Reports file reads, edits and writes, commands and MCP calls."
        case "cursor": return "Reports file reads, commands and MCP calls; not the editor's own writes."
        case "codex": return "Reports commands and MCP calls; no file events."
        default: return "Kai has no hook in this agent: activity unavailable."
        }
    }

    static func n(_ v: Int, _ one: String, _ many: String? = nil) -> String {
        "\(v.formatted()) \(v == 1 ? one : (many ?? one + "s"))"
    }

    /// A path as the user reads it: relative to the workspace, ~ for home.
    static func shown(_ path: String, workspace: String?) -> String {
        if let w = workspace, !w.isEmpty, path.hasPrefix(w + "/") { return String(path.dropFirst(w.count + 1)) }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func examples(_ items: [ActivityGroups.Item], distinct: Int, workspace: String?) -> [String] {
        var ex = items.prefix(3).map { i in
            shown(i.name, workspace: workspace) + (i.count > 1 ? " · \(i.count.formatted())×" : "")
        }
        if distinct > 3 { ex.append("+ \((distinct - 3).formatted()) more") }
        return ex
    }

    static func item(for g: ActivityGroups.Group, workspace: String?) -> ActivityItem? {
        let agent = agentTitle(g.agent)
        let kind = ActivityItem.Kind(rawValue: g.op) ?? .tool
        let paths = n(g.distinct, "distinct path")
        let base = "Requested: Kai saw the agent ask for this through its hook, before the tool ran. "
        let (title, detail, countText, scope, explanation): (String, String, String, String, String)
        switch kind {
        case .read:
            title = "Read project files"; detail = "\(n(g.count, "read")) · \(paths)"
            countText = n(g.count, "read"); scope = "\(paths), repeated reads collapsed"
            explanation = base + "Commands and scripts can read other files that this view doesn't show."
        case .edit:
            title = "Edited project files"; detail = "\(n(g.count, "edit")) · \(paths)"
            countText = n(g.count, "edit"); scope = "\(paths), \(n(g.count, "operation")) grouped"
            explanation = base + "It doesn't confirm the final file content."
        case .write:
            title = "Wrote project files"; detail = "\(n(g.count, "write")) · \(paths)"
            countText = n(g.count, "write"); scope = "\(paths), \(n(g.count, "operation")) grouped"
            explanation = base + "It doesn't confirm the final file content."
        case .command:
            title = "Ran commands"; detail = "\(n(g.count, "command request")) · \(n(g.distinct, "distinct command"))"
            countText = n(g.count, "command"); scope = "\(n(g.distinct, "distinct command")) (first word only)"
            explanation = base + "Kai keeps only each command's first word, never the full command line."
        case .mcp:
            title = "Used MCP tools"; detail = "\(n(g.count, "request")) · \(n(g.distinct, "server"))"
            countText = n(g.count, "request"); scope = n(g.distinct, "MCP server")
            explanation = base + "What a tool did on its service isn't confirmed by Kai."
        default:
            title = "Other tool requests"; detail = n(g.count, "request")
            countText = n(g.count, "request"); scope = n(g.count, "request")
            explanation = base
        }
        return ActivityItem(id: "act-\(g.agent)-\(g.op)", kind: kind, agentKey: g.agent, agent: agent, title: title,
                            detail: detail, count: g.count, countText: countText, outcome: "Requested",
                            source: "\(agent) hook (activity recording)", session: n(g.sessions, "session"),
                            scope: scope, examples: examples(g.items, distinct: g.distinct, workspace: workspace),
                            explanation: explanation)
    }

    static func inWorkspace(_ cwd: String?, _ workspace: String?) -> Bool {
        guard let w = workspace, !w.isEmpty else { return true }
        guard let c = cwd, !c.isEmpty else { return false }
        return c == w || c.hasPrefix(w + "/")
    }

    /// Recorded stops in this workspace today, one entry per stop: a record
    /// with the same decision id (or hash) is listed once.
    static func stops(_ events: [AuditEvent], workspace: String?, now: Date = Date()) -> [AuditEvent] {
        let cal = Calendar.current
        var seen = Set<String>()
        return events.filter { e in
            guard e.isBlock, !e.isNote, !e.isSilent, !e.isGrant,
                  let d = e.date, cal.isDate(d, inSameDayAs: now) else { return false }
            guard e.isNetwork || inWorkspace(e.cwd, workspace) else { return false }
            return seen.insert(e.decision_id ?? e.id).inserted
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 0.5: a command as its program name only ("npm"), never the command line.
    static func program(_ cmd: String) -> String {
        for w in cmd.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            if w.contains("=") { continue }                       // VAR=value (values can be secrets)
            let base = (String(w) as NSString).lastPathComponent
            let clean = base.filter { !"\"'`$();|&".contains($0) }
            if !clean.isEmpty { return String(clean.prefix(40)) }
        }
        return "a command"
    }

    static func stopItem(_ e: AuditEvent, workspace: String?) -> ActivityItem {
        let what = e.excerpt.map { e.actionLabel == "Command" ? program($0) : shown($0, workspace: workspace) }
            ?? (e.actionLabel ?? "an action")
        let title: String
        if e.isPrompt { title = "Prompt stopped" }
        else if e.isNetwork { title = e.blockedSite.map { "Connection to \($0) stopped (your block list)" } ?? "Connection stopped" }
        else if e.actionLabel == "File read" { title = "Sensitive file read stopped" }
        else if e.actionLabel == "File edit" { title = "File change stopped" }
        else if e.actionLabel == "Command" { title = "Command stopped" }
        else { title = "\(e.actionLabel ?? "Action") stopped" }
        let component = e.isNetwork ? "Network wall" : e.isStorage ? "Files wall" : "\(e.agentName) hook"
        return ActivityItem(id: "stop-\(e.decision_id ?? e.id)", kind: .stop, agentKey: e.agentKey, agent: e.agentName,
                            title: title, detail: e.isPrompt ? "the prompt" : what, count: 1, countText: "1 stopped",
                            outcome: "Stopped", source: "Kai recorded decision (\(component))",
                            session: e.session.map { String($0.prefix(8)) } ?? "unknown",
                            scope: e.isPrompt ? "One prompt, not sent" : "This one request, at the agent's tool boundary",
                            examples: (e.isPrompt ? [] : [what]) + (e.decision_id.map { ["Decision: \($0)"] } ?? []),
                            explanation: "Kai stopped this specific request: \(e.detail.sentenceEnded) "
                                + "It doesn't show that other ways to do the same thing were stopped.",
                            decisionID: e.decision_id, eventID: e.id)
    }

    /// Observed connections (Internet watching), grouped by destination.
    static func connections(_ events: [AuditEvent], now: Date = Date()) -> [ActivityItem] {
        let cal = Calendar.current
        let seen = events.filter { e in
            e.isNetwork && !e.isBlock && !e.isSilent && (e.date.map { cal.isDate($0, inSameDayAs: now) } ?? false)
        }
        guard !seen.isEmpty else { return [] }
        var hosts: [String: Int] = [:]
        for e in seen { hosts[e.target ?? "unknown host", default: 0] += 1 }
        let top = hosts.sorted { $0.value > $1.value }
        var ex = top.prefix(3).map { "\($0.key) · \($0.value.formatted())×" }
        if top.count > 3 { ex.append("+ \((top.count - 3).formatted()) more") }
        let mode = InternetMode.current
        return [ActivityItem(id: "net-observed", kind: .connection, agentKey: "", agent: "Attribution partial",
                             title: "Network destinations",
                             detail: "\(n(top.count, "destination")) · " + (mode == .blocklist ? "watching" : "watching only"),
                             count: seen.count, countText: n(seen.count, "connection"), outcome: "Seen",
                             source: mode.evidence, session: "Network watch",
                             scope: "\(n(seen.count, "observed connection")) grouped by destination",
                             examples: ex,
                             explanation: "Connections alone don't show what data was sent. "
                                + (mode == .blocklist ? "None of these sites is on your block list, so they were only recorded."
                                                      : "Internet is Watch only: nothing here was blocked by it."))]
    }

    static func build(groups: ActivityGroups?, events: [AuditEvent], workspace: String?,
                      internetWatching: Bool, now: Date = Date()) -> [ActivityItem] {
        var out: [ActivityItem] = []
        out += stops(events, workspace: workspace, now: now).map { stopItem($0, workspace: workspace) }
        if let g = groups, g.recording || !g.groups.isEmpty {
            let order: [String] = ["edit", "write", "read", "command", "mcp", "tool"]
            out += g.groups.sorted {
                (order.firstIndex(of: $0.op) ?? 9, $1.count) < (order.firstIndex(of: $1.op) ?? 9, $0.count)
            }.compactMap { item(for: $0, workspace: workspace) }
        }
        if internetWatching { out += connections(events, now: now) }
        return out
    }
}

extension String {
    /// The text as a sentence: one final full stop, never two ("Kai..").
    var sentenceEnded: String {
        let t = trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?…".contains(last) ? t : t + "."
    }
}
