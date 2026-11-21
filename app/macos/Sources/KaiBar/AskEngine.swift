// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Ask Kai, 0.4: deterministic answers from Kai's records. Keyword intent
// routing, then an answer built only from structured results (kai activity,
// the audit log's decisions, kai snapshot, kai status), each with a
// "Based on: …" line. No model decides anything here; a phraser may reword
// the text afterwards (AskPhraser.swift). Action buttons come from records,
// never from the text.
//
// Foundation only: compiled into the app tests with AuditLog.swift and
// ActivityFeed.swift.
import Foundation

enum AskIntent: Equatable {
    case today, files, stops, agent(String), destinations, blindSpots, unknown, outOfScope
}

struct AskAction: Equatable, Codable, Hashable {
    enum Kind: String, Codable { case openDecision, allowForSession, reconnect, openActivity, turnOnRecording, turnOnInternet }
    var kind: Kind
    var title: String
    /// Decision id / event id, agent key or filter, as the kind needs.
    var ref: String = ""
}

struct AskAnswer: Equatable {
    var intent: AskIntent
    /// Record values (paths, commands, hosts) are wrapped in <data> tags for
    /// the phraser; `display` is what the user reads.
    var text: String
    var basedOn: String
    var actions: [AskAction] = []
    var display: String { AskAnswer.untag(text) }
    static func untag(_ s: String) -> String {
        s.replacingOccurrences(of: "<data>", with: "").replacingOccurrences(of: "</data>", with: "")
    }
}

/// One agent as Kai measured it (kai snapshot + kai status).
struct AskAgent: Equatable {
    var key: String
    var connected: Bool       // Kai's hooks installed and answering
    var running: Bool         // a session of it is running
    var working: Int          // sessions that ran something in the last 15 minutes
    var problem: String? = nil
}

struct AskContext {
    var workspace: String?
    var recording: Bool
    var internetWatching: Bool
    var items: [ActivityItem]
    var stops: [AuditEvent]
    var agents: [AskAgent]
    /// `kai why` per decision id, when fetched.
    var why: [String: WhyRecord] = [:]
    /// A record the user dropped in with "Ask about this".
    var focus: ActivityItem? = nil
}

enum AskEngine {
    static let suggestions = ["What happened today?", "Which files were changed?",
                              "What did Kai stop?", "Which destinations were contacted?"]

    static let canAnswer = "Kai can answer: what happened today, which files agents read or changed, what Kai "
        + "stopped and why, whether an agent is connected, which destinations were contacted, and what Kai can't see."

    static let agentNames: [(String, [String])] = [
        ("claude", ["claude", "claude code"]), ("cursor", ["cursor"]), ("codex", ["codex"]),
    ]

    static func has(_ t: String, _ words: [String]) -> Bool { words.contains { t.contains($0) } }

    static func route(_ question: String) -> AskIntent {
        let t = " " + question.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let first = question.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let commands = ["write", "fix", "implement", "refactor", "generate", "create", "build", "deploy", "install",
                        "delete", "rename", "translate", "summarize", "debug", "add", "make", "run"]
        if commands.contains(first) || has(t, ["write me", "write a ", "code for", "how do i ", "how to "]) {
            return .outOfScope
        }
        if has(t, ["can't see", "cannot see", "can not see", "blind", "not see", "doesn't see", "coverage",
                   "limit", "what can't", "invisible", "miss"]) { return .blindSpots }
        if has(t, ["connected", "connection to kai", "working", "running", "installed", "hooked", " status"]) {
            for (key, names) in agentNames where has(t, names) { return .agent(key) }
            if has(t, ["connected", "installed"]) { return .agent("") }
        }
        if has(t, ["stop", "block", "denied", "deny", "prevent", "refuse", " why "]) { return .stops }
        if has(t, ["destination", "domain", "host", "network", "internet", "server", "contact", "url", "website",
                   "connect"]) { return .destinations }
        if has(t, ["file", " read", "changed", "change", " edit", "wrote", "write", "modif", "touch"]) { return .files }
        if has(t, ["today", "happen", "summary", "what did", "recent", "activity", "doing", "going on"]) {
            return .today
        }
        for (key, names) in agentNames where has(t, names) { return .agent(key) }
        return .unknown
    }

    static func answer(_ question: String, _ c: AskContext) -> AskAnswer {
        let intent = route(question)
        if let f = c.focus, intent != .outOfScope,
           intent == .unknown || has(" " + question.lowercased() + " ", [" this", " it ", " it?", "that"]) {
            return about(f, c)
        }
        switch intent {
        case .outOfScope:
            return AskAnswer(intent: .outOfScope,
                             text: "Kai only answers from what it recorded; ask your agent for help with the work itself.",
                             basedOn: "Nothing: this isn't a question about Kai's records.")
        case .stops: return stops(c)
        case .files: return files(c)
        case .destinations: return destinations(c)
        case .agent(let k): return agent(k, c)
        case .blindSpots: return blindSpots(c)
        case .today: return today(c)
        case .unknown:
            return AskAnswer(intent: .unknown, text: "No matching record. " + canAnswer,
                             basedOn: "Nothing matched this question in Kai's records.")
        }
    }

    static var whereText: (AskContext) -> String = { c in
        c.workspace.map { " in " + ($0 as NSString).lastPathComponent } ?? ""
    }

    // MARK: intents

    static func stops(_ c: AskContext) -> AskAnswer {
        let s = c.stops
        guard !s.isEmpty else {
            return AskAnswer(intent: .stops,
                             text: "No matching record: Kai recorded no stops\(whereText(c)) today. That doesn't "
                                + "mean every action was checked.",
                             basedOn: "Kai's decisions (audit log), today")
        }
        let lines = s.prefix(3).map { e -> String in
            var l = "\(e.agentName): \(ActivityFeed.stopItem(e, workspace: c.workspace).title.lowercased()) "
                + "(\(PhrasePrompts.data(ActivityFeed.stopItem(e, workspace: c.workspace).detail))), "
                + "because \(e.detail.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))"
            if let id = e.decision_id, let r = c.why[id]?.retryLine { l += "; \(r.lowercased())" }
            return l + "."
        }
        let more = s.count > 3 ? " And \(s.count - 3) more in Decisions." : ""
        var actions: [AskAction] = s.prefix(3).map {
            AskAction(kind: .openDecision, title: "Open decision", ref: $0.decision_id ?? $0.id)
        }
        if actions.count > 1 { actions = [AskAction(kind: .openActivity, title: "Open Decisions", ref: "stops")] }
        return AskAnswer(intent: .stops,
                         text: "Kai recorded \(ActivityFeed.n(s.count, "stop"))\(whereText(c)) today. "
                            + lines.joined(separator: " ") + more,
                         basedOn: "Kai's decisions (audit log)" + (c.why.isEmpty ? "" : " and kai why") + ", today",
                         actions: actions)
    }

    static func files(_ c: AskContext) -> AskAnswer {
        guard c.recording || c.items.contains(where: { [.read, .edit, .write].contains($0.kind) }) else {
            return AskAnswer(intent: .files,
                             text: "No matching record: activity recording is off, so Kai has no list of files "
                                + "agents read or changed. Kai still records what it stopped.",
                             basedOn: "Settings: activity recording is off",
                             actions: [AskAction(kind: .turnOnRecording, title: "Turn on activity recording")])
        }
        let f = c.items.filter { [.read, .edit, .write].contains($0.kind) }
        guard !f.isEmpty else {
            return AskAnswer(intent: .files,
                             text: "No matching record: Kai recorded no file reads or changes\(whereText(c)) today. "
                                + "Cursor doesn't report its editor's writes and Codex reports no file events.",
                             basedOn: "kai activity, today")
        }
        let lines = f.prefix(4).map { i in
            "\(i.agent) \(i.title.lowercased()): \(i.detail)"
                + (i.examples.isEmpty ? "" : " (for example \(PhrasePrompts.data(i.examples[0])))")
        }
        return AskAnswer(intent: .files,
                         text: lines.joined(separator: ". ") + ". These are requests Kai saw through the agents' "
                            + "hooks, not every file access: commands and scripts can touch other files.",
                         basedOn: "kai activity (activity recording), today",
                         actions: [AskAction(kind: .openActivity, title: "Open Activity", ref: "files")])
    }

    static func destinations(_ c: AskContext) -> AskAnswer {
        guard c.internetWatching else {
            return AskAnswer(intent: .destinations,
                             text: "No matching record: Internet watching is off, so Kai has no list of "
                                + "destinations. It can't say which were or weren't contacted.",
                             basedOn: "Settings: Internet watching is off",
                             actions: [AskAction(kind: .turnOnInternet, title: "Internet settings")])
        }
        let n = c.items.filter { $0.kind == .connection }
        guard let g = n.first else {
            return AskAnswer(intent: .destinations,
                             text: "No matching record: Kai observed no connections today.",
                             basedOn: "Network wall (Watch only), today")
        }
        return AskAnswer(intent: .destinations,
                         text: "Kai observed \(g.countText) to \(g.detail.replacingOccurrences(of: " · watching only", with: "")): "
                            + g.examples.map(PhrasePrompts.data).joined(separator: ", ")
                            + ". Internet is Watch-only: nothing was blocked, and a connection doesn't show what was sent.",
                         basedOn: "Network wall (Watch only), today",
                         actions: [AskAction(kind: .openActivity, title: "Open Activity", ref: "connections")])
    }

    static func agentWords(_ a: AskAgent) -> String {
        let name = ActivityFeed.agentTitle(a.key)
        if a.connected {
            return "\(name) is connected" + (a.working > 0 ? " · \(a.working) working" : "") + "."
        }
        return "\(name) is not connected" + (a.running ? ", but it's running: activity unknown." : ": activity unavailable.")
            + (a.problem.map { " (\($0.sentenceEnded.dropLast()))" } ?? "")
    }

    static func agent(_ key: String, _ c: AskContext) -> AskAnswer {
        let rows = key.isEmpty ? c.agents : c.agents.filter { $0.key == key }
        guard !rows.isEmpty else {
            return AskAnswer(intent: .agent(key),
                             text: "No matching record: Kai didn't find \(ActivityFeed.agentTitle(key)) on this Mac.",
                             basedOn: "kai snapshot (agents found on this Mac)")
        }
        let actions = rows.filter { !$0.connected }.map {
            AskAction(kind: .reconnect, title: "Reconnect \(ActivityFeed.agentTitle($0.key))", ref: $0.key)
        }
        return AskAnswer(intent: .agent(key),
                         text: rows.map(agentWords).joined(separator: " ")
                            + " Connected is about Kai's integration only; working means a connected agent ran a "
                            + "command in the last 15 minutes.",
                         basedOn: "kai snapshot and kai status", actions: actions)
    }

    static func blindSpots(_ c: AskContext) -> AskAnswer {
        var s = ["Kai's checks run inside each agent (hooks): a script or program the agent starts can read or "
                 + "change files Kai doesn't see.",
                 "Claude Code reports reads, edits and writes; Cursor reports reads but not its editor's writes; "
                 + "Codex reports commands and MCP calls but no file events.",
                 "Internet is Watch-only: Kai can list destinations when watching is on, never what was sent."]
        if !c.recording { s.append("Activity recording is off, so Kai keeps only its stops.") }
        if !c.internetWatching { s.append("Internet watching is off.") }
        return AskAnswer(intent: .blindSpots, text: s.joined(separator: " "),
                         basedOn: "Kai's coverage notes (docs/COVERAGE.md) and your settings")
    }

    static func today(_ c: AskContext) -> AskAnswer {
        var parts: [String] = []
        let working = c.agents.filter { $0.connected && $0.working > 0 }
        if !working.isEmpty {
            parts.append(working.map { "\(ActivityFeed.agentTitle($0.key)) has \(ActivityFeed.n($0.working, "working session"))" }
                .joined(separator: ", "))
        }
        let acts = c.items.filter { $0.kind != .stop }
        if !acts.isEmpty { parts.append(acts.prefix(4).map { "\($0.agent): \($0.title.lowercased()), \($0.countText)" }.joined(separator: "; ")) }
        else if !c.recording { parts.append("activity recording is off, so Kai has no list of reads, edits or commands") }
        parts.append(c.stops.isEmpty ? "Kai recorded no stops" : "Kai recorded \(ActivityFeed.n(c.stops.count, "stop"))")
        let text = "Today\(whereText(c)): " + parts.joined(separator: ". ") + "."
        var actions = [AskAction(kind: .openActivity, title: "Open Activity", ref: "all")]
        if !c.recording { actions.append(AskAction(kind: .turnOnRecording, title: "Turn on activity recording")) }
        return AskAnswer(intent: .today, text: text,
                         basedOn: (c.recording ? "kai activity, " : "") + "Kai's decisions and kai snapshot, today",
                         actions: actions)
    }

    /// "Ask about this": the record dropped in, explained from itself.
    static func about(_ i: ActivityItem, _ c: AskContext) -> AskAnswer {
        var text = "\(i.title) (\(i.agent)): \(i.outcome.lowercased()). \(i.explanation)"
        if let id = i.decisionID, let r = c.why[id] {
            if let reason = r.reason, !reason.isEmpty { text += " Reason: \(reason.sentenceEnded)" }
            if let l = r.retryLine { text += " \(l.sentenceEnded)" }
        }
        var actions: [AskAction] = []
        if i.kind == .stop { actions.append(AskAction(kind: .openDecision, title: "Open decision", ref: i.decisionID ?? i.eventID ?? "")) }
        return AskAnswer(intent: .unknown, text: text, basedOn: i.source, actions: actions)
    }
}
