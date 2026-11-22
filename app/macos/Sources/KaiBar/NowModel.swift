// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5 Now: one card per live agent session, built from `kai snapshot --json`
// (the sessions) and `kai activity --json` "sessions" (counts and the newest
// events per Kai session key). Every number on Now, in the toolbar pill and
// in the popover comes from NowSummary, so they can't disagree.
//
// Only what the agent reports is counted: Cursor's editor writes and Codex's
// file events aren't reported, so those cards say "not reported" instead of
// a number (the coverage table in ActivityFeed.coverage).
//
// Paths are shown as a file name; a command only as its program name (the
// recorder keeps the first word, never the command line).
//
// Foundation only: compiled into the app tests.
import Foundation

/// `kai activity --json` "sessions": one Kai session's recorded activity.
struct SessionActivity: Decodable, Equatable {
    struct Counts: Decodable, Equatable {
        var read = 0, edit = 0, write = 0, command = 0, mcp = 0, tool = 0
        enum CodingKeys: String, CodingKey { case read, edit, write, command, mcp, tool }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v(_ k: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) .flatMap { $0 } ?? 0 }
            read = v(.read); edit = v(.edit); write = v(.write); command = v(.command); mcp = v(.mcp); tool = v(.tool)
        }
        static func + (a: Counts, b: Counts) -> Counts {
            var r = Counts()
            r.read = a.read + b.read; r.edit = a.edit + b.edit; r.write = a.write + b.write
            r.command = a.command + b.command; r.mcp = a.mcp + b.mcp; r.tool = a.tool + b.tool
            return r
        }
    }
    struct Event: Decodable, Equatable {
        var ts: Double
        var op: String
        var name: String? = nil
        var decision: String = "allow"
        var isStop: Bool { decision == "block" || decision == "deny" }
    }
    var key: String
    var agent: String
    var workspace: String = ""
    var first: Double = 0
    var last: Double = 0
    var counts = Counts()
    var stops: Int = 0
    var events: [Event] = []

    enum CodingKeys: String, CodingKey { case key, agent, workspace, first, last, counts, stops, events }
    init(key: String, agent: String) { self.key = key; self.agent = agent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        agent = try c.decode(String.self, forKey: .agent)
        workspace = ((try? c.decodeIfPresent(String.self, forKey: .workspace)) ?? nil) ?? ""
        first = ((try? c.decodeIfPresent(Double.self, forKey: .first)) ?? nil) ?? 0
        last = ((try? c.decodeIfPresent(Double.self, forKey: .last)) ?? nil) ?? 0
        counts = ((try? c.decodeIfPresent(Counts.self, forKey: .counts)) ?? nil) ?? Counts()
        stops = ((try? c.decodeIfPresent(Int.self, forKey: .stops)) ?? nil) ?? 0
        events = ((try? c.decodeIfPresent(LossyEvents.self, forKey: .events)) ?? nil)?.items ?? []
    }
    private struct LossyEvents: Decodable {
        var items: [Event] = []
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            while !c.isAtEnd {
                if let e = try? c.decode(Event.self) { items.append(e) } else { _ = try? c.decode(Skip.self) }
            }
        }
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    }
}

/// What a card counts, by the words the user reads.
enum CountKind: String, CaseIterable { case reads, edits, commands, connections, stops }

/// One count on a card: a number, or "not reported by <agent>".
struct CardCount: Equatable {
    var kind: CountKind
    var value: Int?
    var notReportedBy: String? = nil
    var text: String {
        if let who = notReportedBy { return "\(kind.rawValue): not reported by \(who)" }
        let v = value ?? 0
        let one: [CountKind: String] = [.reads: "read", .edits: "edit", .commands: "command",
                                        .connections: "connection", .stops: "stop"]
        return "\(v.formatted()) \(v == 1 ? one[kind]! : kind.rawValue)"
    }
}

/// What each agent's hooks report, from the coverage table (ActivityFeed.coverage).
enum AgentReports {
    /// The count kinds this agent's hooks don't report: never shown as a number.
    static func notReported(_ agent: String) -> [CountKind] {
        switch agent {
        case "cursor": return [.edits]          // "not the editor's own writes"
        case "codex": return [.reads, .edits]   // "no file events"
        default: return []
        }
    }
    /// The one short note a card footer shows (only where something isn't reported).
    static func footnote(_ agent: String) -> String? {
        switch agent {
        case "cursor": return "edits: not reported by Cursor"
        case "codex": return "files: not reported by Codex"
        default: return nil
        }
    }
}

/// The last action, said the way the card's most important line says it.
enum LastAction {
    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    /// "1h", "6 min", "now": the popover's short age.
    static func short(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// A file name, never the full path; a program name, never a command line.
    static func object(_ e: SessionActivity.Event) -> String? {
        guard let n = e.name, !n.isEmpty else { return nil }
        switch e.op {
        case "command", "mcp": return String(n.prefix(40))
        default: return (n as NSString).lastPathComponent
        }
    }

    /// "Editing Pricing.tsx · now", "Read package.json · 2 min ago",
    /// "Ran npm · 5 min ago", "Kai stopped Claude Code reading .env · now".
    /// 0.5.1: a stop always has Kai as its subject.
    static func line(_ e: SessionActivity.Event, now: Date, agent: String? = nil) -> String {
        line(e, now: now, agent: agent, withAgo: true)
    }
    static func what(_ e: SessionActivity.Event, now: Date, agent: String? = nil) -> String {
        line(e, now: now, agent: agent, withAgo: false)
    }
    private static func line(_ e: SessionActivity.Event, now: Date, agent: String?, withAgo: Bool) -> String {
        let fresh = now.timeIntervalSince1970 - e.ts < 60
        let obj = object(e)
        let what: String
        if e.isStop {
            let k = StopWords.kind(op: e.op)
            if let a = agent {
                what = StopWords.line(agent: a, kind: k, object: k == .read || k == .change ? obj : nil)
            } else {
                let noun = e.op == "read" ? "a read" : e.op == "command" ? "a command" : e.op == "mcp" ? "an MCP call"
                    : (e.op == "edit" || e.op == "write") ? "a change" : "a request"
                what = "Kai stopped \(noun)" + (obj.map { " of \($0)" } ?? "")
            }
        } else {
            switch e.op {
            case "read": what = (fresh ? "Reading " : "Read ") + (obj ?? "a file")
            case "edit": what = (fresh ? "Editing " : "Edited ") + (obj ?? "a file")
            case "write": what = (fresh ? "Writing " : "Wrote ") + (obj ?? "a file")
            case "command": what = obj.map { (fresh ? "Running " : "Ran ") + $0 } ?? (fresh ? "Running a command" : "Ran a command")
            case "mcp": what = "Used " + (obj.map { "the \($0) MCP tool" } ?? "an MCP tool")
            default: what = "Used a tool"
            }
        }
        return withAgo ? what + " · " + ago(now.timeIntervalSince1970 - e.ts) : what
    }
}

/// One live session as the Now page shows it.
struct NowCard: Identifiable, Equatable {
    var session: SessionRow
    /// Nested sessions and background services under this one.
    var children: [SessionRow] = []
    var activity: SessionActivity? = nil
    /// The newest stop Kai recorded for this session (an audit record).
    var latestStop: AuditEvent? = nil
    var stopCount: Int = 0
    var connections: Int? = nil
    var id: String { session.id }
    var agentKey: String { session.agent }
    var working: Bool { session.isWorking }

    var counts: [CardCount] {
        let c = activity?.counts ?? SessionActivity.Counts()
        let missing = AgentReports.notReported(agentKey)
        let who = session.displayAgent
        var out: [CardCount] = []
        func add(_ k: CountKind, _ v: Int?) {
            out.append(missing.contains(k) ? CardCount(kind: k, value: nil, notReportedBy: who) : CardCount(kind: k, value: v))
        }
        add(.reads, c.read)
        add(.edits, c.edit + c.write)
        add(.commands, c.command)
        if let n = connections { add(.connections, n) }
        add(.stops, max(stopCount, activity?.stops ?? 0))
        return out
    }

    /// The project folder name ("—" when unknown).
    var project: String { session.projectName }

    /// "Working" or "Idle 12 min".
    func statePill(now: Date) -> String {
        if session.isWorking { return "Working" }
        guard session.lastActiveUtc > 0 else { return "Idle" }
        let m = max(0, Int(now.timeIntervalSince1970) - session.lastActiveUtc) / 60
        if m < 60 { return "Idle \(max(1, m)) min" }
        return "Idle \(m / 60) h"
    }

    /// "started 18:42 · 37 min".
    func started(now: Date) -> String {
        guard session.startedUtc > 0 else { return "" }
        let d = Date(timeIntervalSince1970: TimeInterval(session.startedUtc))
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
        let s = max(0, Int(now.timeIntervalSince(d)))
        let dur = s >= 86400 ? "\(s / 86400) d \((s % 86400) / 3600) h" : s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60) min" : "\(max(1, s / 60)) min"
        return "started \(f.string(from: d)) · \(dur)"
    }

    /// The card's most important line (nil when nothing was recorded yet).
    func lastLine(now: Date) -> String? {
        guard let e = activity?.events.first else { return nil }
        return LastAction.line(e, now: now, agent: session.displayAgent)
    }
}

/// One agent's cards: "Claude Code · 2 working".
struct NowSection: Identifiable, Equatable {
    var agent: String
    var title: String
    var cards: [NowCard]
    var id: String { agent }
    var line: String {
        let w = cards.filter(\.working).count, i = cards.count - w
        var parts: [String] = []
        if w > 0 { parts.append("\(w) working") }
        if i > 0 { parts.append("\(i) idle") }
        return ([title] + parts).joined(separator: " · ")
    }
}

/// The one source for "2 working · 1 idle" (Now header, toolbar pill, popover).
struct NowSummary: Equatable {
    var working: Int
    var idle: Int
    var text: String {
        if working == 0 && idle == 0 { return "No session running" }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }
    static func of(_ sections: [NowSection]) -> NowSummary {
        let cards = sections.flatMap(\.cards)
        let w = cards.filter(\.working).count
        return NowSummary(working: w, idle: cards.count - w)
    }
}

enum NowBuilder {
    /// The activity records that belong to a session: by Kai's session keys,
    /// else (records from before 0.5) by agent and project when only one live
    /// session of that agent works in that project. IDE apps are one row, so
    /// all of the app's records are its.
    static func activity(for s: SessionRow, among all: [SessionRow], records: [SessionActivity]) -> SessionActivity? {
        let keys = Set(s.activityKeys)
        var mine = records.filter { keys.contains($0.key) && $0.agent == s.agent }
        if s.isIDE {
            mine = records.filter { $0.agent == s.agent }
        } else if !s.project.isEmpty && s.project != "/" {
            let peers = all.filter { $0.isActive && $0.isSession && $0.agent == s.agent && $0.project == s.project }
            if peers.count == 1 {
                let claimed = Set(all.flatMap(\.activityKeys))
                mine += records.filter { r in
                    r.agent == s.agent && !claimed.contains(r.key) && !keys.contains(r.key)
                        && ActivityFeed.inWorkspace(r.workspace, s.project)
                        && (s.startedUtc == 0 || r.last >= Double(s.startedUtc))
                }
            }
        }
        guard !mine.isEmpty else { return nil }
        var merged = SessionActivity(key: mine.map(\.key).joined(separator: "+"), agent: s.agent)
        merged.workspace = mine.max { $0.last < $1.last }?.workspace ?? ""
        merged.first = mine.map(\.first).min() ?? 0
        merged.last = mine.map(\.last).max() ?? 0
        merged.counts = mine.reduce(SessionActivity.Counts()) { $0 + $1.counts }
        merged.stops = mine.reduce(0) { $0 + $1.stops }
        merged.events = mine.flatMap(\.events).sorted { $0.ts > $1.ts }
        return merged
    }

    /// Kai's recorded stops for a session: same agent, inside its project
    /// (or any project for an IDE app), since it started.
    static func stops(for s: SessionRow, _ events: [AuditEvent], among all: [SessionRow] = []) -> [AuditEvent] {
        events.filter { e in
            guard e.isBlock, !e.isNote, !e.isSilent, !e.isGrant, e.agentKey == s.agent else { return false }
            if s.startedUtc > 0, let d = e.date, d.timeIntervalSince1970 < Double(s.startedUtc) { return false }
            // 0.5.1: a connection Kai refused (blocked site) belongs to the
            // session the network extension named, else to the agent's only
            // live session (connections carry no folder).
            if e.isNetwork {
                guard e.blockedSite != nil else { return false }
                if let sid = e.session, !sid.isEmpty { return sid == s.id || s.activityKeys.contains(sid) }
                let peers = all.filter { $0.isActive && $0.isSession && $0.agent == s.agent }
                return s.isIDE || peers.count <= 1
            }
            if s.isIDE { return true }
            return !s.project.isEmpty && ActivityFeed.inWorkspace(e.cwd, s.project)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Live sessions grouped by agent; nested sessions and background services
    /// under their parent (same agent and project), never as their own card.
    static func sections(sessions: [SessionRow], records: [SessionActivity], events: [AuditEvent],
                         connections: [String: Int]? = nil) -> [NowSection] {
        let live = sessions.filter(\.isActive)
        let parents = live.filter(\.isSession)
        let extras = live.filter { !$0.isSession }
        var cards: [NowCard] = parents.map { s in
            let st = stops(for: s, events, among: live)
            var c = NowCard(session: s, activity: activity(for: s, among: sessions, records: records),
                            latestStop: st.first, stopCount: st.count)
            if let n = connections?[s.agent] { c.connections = n }
            return c
        }
        for x in extras {
            if let i = cards.firstIndex(where: { $0.session.agent == x.agent && $0.session.project == x.project })
                ?? cards.firstIndex(where: { $0.session.agent == x.agent }) {
                cards[i].children.append(x)
            }
        }
        let order = ["claude", "cursor", "codex"]
        let byAgent = Dictionary(grouping: cards, by: \.agentKey)
        return byAgent.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }.map { k in
            let list = byAgent[k]!.sorted { a, b in
                if a.working != b.working { return a.working }
                return max(a.session.lastActiveUtc, a.session.startedUtc) > max(b.session.lastActiveUtc, b.session.startedUtc)
            }
            return NowSection(agent: k, title: list[0].session.displayAgent, cards: list)
        }
    }

    /// Interactive sessions that ended today, newest first ("Earlier today (n)").
    static func endedToday(_ sessions: [SessionRow], now: Date) -> [SessionRow] {
        sessions.filter { s in
            !s.isActive && s.isSession && s.endedUtc > 0
                && Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(s.endedUtc)), inSameDayAs: now)
        }.sorted { $0.endedUtc > $1.endedUtc }
    }

    /// "No agent is working right now. Kai is connected to Claude Code and Codex."
    static func emptyText(connected: [String]) -> String {
        let names = connected.map(ActivityFeed.agentTitle)
        if names.isEmpty { return "No agent is working right now. Kai isn't connected to an agent yet." }
        return "No agent is working right now. Kai is connected to \(AutoConnectWords.joined(names))."
    }
}

// MARK: - Activity timeline (0.5)

/// One row of the Activity timeline.
struct TimelineEvent: Identifiable, Equatable {
    enum Kind: String { case file, command, connection, stop, tool }
    var id: String
    var kind: Kind
    var ts: Double
    var agent: String
    var title: String
    /// What the record shows (a shortened path, a program name).
    var object: String
    var outcome: String
    var evidence: String
    var what: String
    /// Stops: the audit record (opens DecisionDetailSheet).
    var stopEventID: String? = nil
    /// 0.5.1: the evidence level behind the plain label (shown in the sheet).
    var evidenceLevel: String = ""
    /// The full path, for the detail sheet only (rows show it relative).
    var fullPath: String = ""
    /// A connection's site (Seen or Stopped): Block site / Unblock.
    var site: String? = nil
    var isConnection: Bool { kind == .connection || site != nil }
}

/// The kind segments: All · Files · Commands · Connections · Stops.
enum TimelineFilter: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", commands = "Commands", connections = "Connections", stops = "Stops"
    var id: String { rawValue }
    func matches(_ e: TimelineEvent) -> Bool {
        if self == .connections { return e.isConnection }
        return matches(e.kind)
    }
    func matches(_ k: TimelineEvent.Kind) -> Bool {
        switch self {
        case .all: return true
        case .files: return k == .file
        case .commands: return k == .command
        case .connections: return k == .connection
        case .stops: return k == .stop
        }
    }
}

/// One session's block in the timeline: "Claude Code · acme-web · 18:42–now".
struct TimelineGroup: Identifiable, Equatable {
    var id: String
    var agent: String
    var project: String
    var projectPath: String = ""
    var sessionID: String?
    var start: Double
    var end: Double?
    var events: [TimelineEvent]
    /// 0.5.1: the recorded counts of the records in this group (the same
    /// sums the session's Now card shows), and when they begin.
    var counts = SessionActivity.Counts()
    var firstRecord: Double = 0
    var recorded: RecordedSummary? {
        guard firstRecord > 0 else { return nil }
        var a = SessionActivity(key: id, agent: agent)
        a.counts = counts; a.first = firstRecord
        return RecordedSummary.of(a)
    }
    func header(now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let a = f.string(from: Date(timeIntervalSince1970: start))
        let b = end.map { f.string(from: Date(timeIntervalSince1970: $0)) } ?? "now"
        return [ActivityFeed.agentTitle(agent), project, "\(a)–\(b)"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum Timeline {
    static func event(_ e: SessionActivity.Event, agent: String, key: String, index: Int, workspace: String?) -> TimelineEvent {
        let raw = e.name ?? ""
        let isFile = e.op != "command" && e.op != "mcp"
        // 0.5.1: paths relative to the session's project; outside it, "outside
        // project" and the file name; the full path only in the sheet.
        let name = isFile ? (raw.isEmpty ? "" : PathWords.text(raw, project: workspace)) : raw
        let file = raw.isEmpty ? "" : (raw as NSString).lastPathComponent
        let who = ActivityFeed.agentTitle(agent)
        let base = "\(who) asked for this through its hook, before the tool ran."
        let kind: TimelineEvent.Kind
        let title: String, what: String
        switch e.op {
        case "read":
            kind = .file; title = "Read " + (file.isEmpty ? "a file" : file)
            what = base + " Commands and scripts can read other files that this list doesn't show."
        case "edit", "write":
            kind = .file; title = (e.op == "edit" ? "Edited " : "Wrote ") + (file.isEmpty ? "a file" : file)
            what = base + " It doesn't confirm the final file content."
        case "command":
            kind = .command; title = raw.isEmpty ? "Ran a command" : "Ran \(raw)"
            what = base + " Kai keeps only the program's name, never the full command line, and doesn't know if it succeeded."
        case "mcp":
            kind = .tool; title = raw.isEmpty ? "Used an MCP tool" : "Used the \(raw) MCP tool"
            what = base + " What the tool did on its service isn't confirmed by Kai."
        default:
            kind = .tool; title = "Used a tool"; what = base
        }
        let stopped = e.isStop
        let k: TimelineEvent.Kind = stopped ? .stop : kind
        return TimelineEvent(id: "\(key)-\(Int(e.ts))-\(index)", kind: k, ts: e.ts, agent: agent,
                             title: stopped ? LastAction.what(e, now: Date(timeIntervalSince1970: e.ts), agent: who) : title,
                             object: name, outcome: EventWords.label(k, op: e.op),
                             evidence: "\(who) hook (activity recording)",
                             what: stopped ? "Kai stopped this request at the agent's tool boundary." : what,
                             evidenceLevel: EventWords.evidenceLevel(k),
                             fullPath: isFile ? ActivityFeed.shown(raw, workspace: nil) : "")
    }

    /// 0.5.1: temp and scratchpad files in one row per group ("tmp · 3 files").
    static func groupTemp(_ events: [TimelineEvent]) -> [TimelineEvent] {
        let temp = events.filter { $0.kind == .file && $0.object.hasPrefix("tmp · ") }
        guard temp.count > 1, let newest = temp.max(by: { $0.ts < $1.ts }) else { return events }
        let files = Set(temp.map(\.fullPath)).count
        let anyWrite = temp.contains { $0.outcome == EventWords.label(.file, op: "write") }
        var row = newest
        row.id = "tmp-" + newest.id
        row.title = "Temporary files"
        row.object = "tmp · " + ActivityFeed.n(files, "file")
        row.outcome = EventWords.label(.file, op: anyWrite ? "write" : "read")
        row.fullPath = temp.map(\.fullPath).filter { !$0.isEmpty }.prefix(5).joined(separator: "\n")
        row.what = "\(ActivityFeed.n(temp.count, "request")) for files in temporary folders, grouped. " + newest.what
        return events.filter { !temp.contains($0) } + [row]
    }
}

/// Now → "Ask about this": the session as its card shows it (Ask Kai's focus).
struct SessionFocus: Equatable {
    var id: String
    var agent: String
    var agentTitle: String
    var project: String
    var tab: String
    var state: String
    var started: String
    var counts: [CardCount]
    var last: String?
    var stops: Int
    var stopLine: String?
    var topic: String
    var recording: Bool
}

extension NowCard {
    func focus(now: Date, recording: Bool) -> SessionFocus {
        SessionFocus(id: session.id, agent: agentKey, agentTitle: session.displayAgent, project: project,
                     tab: session.tab, state: statePill(now: now), started: started(now: now), counts: counts,
                     last: lastLine(now: now), stops: max(stopCount, activity?.stops ?? 0),
                     stopLine: latestStop.map { NowCard.stopLine($0) }, topic: session.topic.trimmingCharacters(in: .whitespacesAndNewlines),
                     recording: recording)
    }

    /// "Kai stopped Claude Code reading .env" (one line on the card; the
    /// sheet has the rest). 0.5.1: Kai is always the subject.
    static func stopLine(_ e: AuditEvent) -> String { StopWords.line(e) }
}

extension Timeline {
    /// The snapshot session a record belongs to (the inverse of NowBuilder.activity).
    static func session(for r: SessionActivity, in sessions: [SessionRow]) -> SessionRow? {
        if let s = sessions.first(where: { $0.agent == r.agent && $0.activityKeys.contains(r.key) }) { return s }
        if let ide = sessions.first(where: { $0.agent == r.agent && $0.isIDE }) { return ide }
        let cands = sessions.filter { $0.isSession && $0.agent == r.agent && !$0.project.isEmpty && $0.project != "/"
            && ActivityFeed.inWorkspace(r.workspace, $0.project) && ($0.startedUtc == 0 || r.last >= Double($0.startedUtc)) }
        return cands.count == 1 ? cands[0] : nil
    }

    /// One group per session (records merged by session), newest first; Kai's
    /// stops without a matching record (recording off) in their own group per
    /// agent and folder; observed connections in one group.
    static func groups(records: [SessionActivity], sessions: [SessionRow], events: [AuditEvent],
                       internetWatching: Bool, now: Date = Date()) -> [TimelineGroup] {
        var out: [String: TimelineGroup] = [:]
        var stopTimes: [(agent: String, ts: Double)] = []
        let cal = Calendar.current
        let auditStops = events.filter { e in
            e.isBlock && !e.isNote && !e.isSilent && !e.isGrant && !e.isNetwork
                && (e.date.map { cal.isDate($0, inSameDayAs: now) } ?? false)
        }
        for r in records {
            let s = session(for: r, in: sessions)
            let gid = s.map { "s-" + $0.id } ?? "r-" + r.key
            let path = s.map { $0.isIDE ? r.workspace : $0.project } ?? r.workspace
            let name = s.map { $0.isIDE ? (r.workspace.isEmpty ? $0.displayAgent : (r.workspace as NSString).lastPathComponent) : $0.projectName }
                ?? (r.workspace.isEmpty ? "" : (r.workspace as NSString).lastPathComponent)
            var g = out[gid] ?? TimelineGroup(id: gid, agent: r.agent, project: name, projectPath: path, sessionID: s?.id,
                                              start: s.map { $0.startedUtc > 0 ? Double($0.startedUtc) : r.first } ?? r.first,
                                              end: (s?.isActive ?? false) ? nil : r.last, events: [])
            for (i, e) in r.events.enumerated() {
                var t = event(e, agent: r.agent, key: r.key, index: i, workspace: path.isEmpty ? nil : path)
                if e.isStop {
                    stopTimes.append((r.agent, e.ts))
                    t.stopEventID = auditStops.first { $0.agentKey == r.agent
                        && abs(($0.date?.timeIntervalSince1970 ?? 0) - e.ts) < 3 }?.id
                }
                g.events.append(t)
            }
            g.start = min(g.start, r.first)
            g.counts = g.counts + r.counts
            g.firstRecord = g.firstRecord == 0 ? r.first : min(g.firstRecord, r.first)
            out[gid] = g
        }
        // Stops Kai recorded that no activity line covers (recording off, or older records).
        for e in auditStops {
            let ts = e.date?.timeIntervalSince1970 ?? 0
            if stopTimes.contains(where: { $0.agent == e.agentKey && abs($0.ts - ts) < 3 }) { continue }
            let s = sessions.first { $0.agent == e.agentKey && $0.isSession && !$0.project.isEmpty
                && ActivityFeed.inWorkspace(e.cwd, $0.project) && ($0.startedUtc == 0 || ts >= Double($0.startedUtc)) }
            let gid = s.map { "s-" + $0.id } ?? "stops-\(e.agentKey)-\(e.cwd ?? "")"
            var g = out[gid] ?? TimelineGroup(id: gid, agent: e.agentKey,
                                              project: s?.projectName ?? (e.cwd.map { ($0 as NSString).lastPathComponent } ?? ""),
                                              projectPath: s?.project ?? (e.cwd ?? ""), sessionID: s?.id,
                                              start: s.map { Double($0.startedUtc) } ?? ts, end: s?.isActive == true ? nil : ts,
                                              events: [])
            let item = ActivityFeed.stopItem(e, workspace: g.projectPath.isEmpty ? nil : g.projectPath)
            let shownObj = e.actionLabel == "Command" ? item.detail
                : (e.excerpt.map { PathWords.text($0, project: g.projectPath.isEmpty ? nil : g.projectPath) } ?? item.detail)
            g.events.append(TimelineEvent(id: "stop-" + e.id, kind: .stop, ts: ts, agent: e.agentKey,
                                          title: StopWords.line(e), object: shownObj, outcome: "Stopped",
                                          evidence: item.source, what: item.explanation, stopEventID: e.id,
                                          evidenceLevel: EventWords.evidenceLevel(.stop),
                                          fullPath: e.actionLabel == "Command" ? "" : (e.excerpt ?? "")))
            if g.start == 0 || ts < g.start { g.start = ts }
            out[gid] = g
        }
        if internetWatching {
            let mode = InternetMode.current
            // Seen connections, and (0.5.1) the ones Kai refused because the
            // site is on the block list: "Stopped", with Unblock.
            let seen = events.filter { e in
                e.isNetwork && (!e.isBlock || e.blockedSite != nil) && !e.isSilent
                    && (e.date.map { cal.isDate($0, inSameDayAs: now) } ?? false)
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(60)
            if !seen.isEmpty {
                let evs = seen.map { e -> TimelineEvent in
                    let host = e.target.map { $0.hasPrefix("[") || !$0.contains(":") ? $0 : String($0.split(separator: ":")[0]) }
                    if let site = e.blockedSite {
                        return TimelineEvent(id: "net-" + e.id, kind: .stop, ts: e.date?.timeIntervalSince1970 ?? 0,
                                             agent: e.agentKey, title: StopWords.line(e), object: site, outcome: "Stopped",
                                             evidence: "Network wall (Watch + block my list)",
                                             what: "Kai refused this connection because \(site) is on your block list. "
                                                + "It doesn't show that the agent didn't reach the site another way.",
                                             stopEventID: nil, evidenceLevel: EventWords.evidenceLevel(.stop),
                                             site: host ?? site)
                    }
                    return TimelineEvent(id: "net-" + e.id, kind: .connection, ts: e.date?.timeIntervalSince1970 ?? 0,
                                         agent: e.agentKey, title: "Connected to " + (e.target ?? "an unknown host"),
                                         object: e.target ?? "", outcome: EventWords.label(.connection),
                                         evidence: mode.evidence,
                                         what: "Kai observed this connection. It doesn't show what data was sent. "
                                            + (mode == .blocklist ? "The site isn't on your block list, so it was only recorded."
                                                                  : "Internet is Watch only: nothing was blocked."),
                                         evidenceLevel: EventWords.evidenceLevel(.connection),
                                         site: (e.isUnknownHost ? nil : host))
                }
                out["net"] = TimelineGroup(id: "net", agent: "", project: "Connections", sessionID: nil,
                                           start: evs.map(\.ts).min() ?? 0, end: nil, events: Array(evs))
            }
        }
        return out.values.map { g in
            var g = g
            g.events = groupTemp(g.events)
            g.events.sort { $0.ts > $1.ts }
            return g
        }.sorted { ($0.events.first?.ts ?? $0.start) > ($1.events.first?.ts ?? $1.start) }
    }

    /// Why the (filtered) timeline is empty, in the real state's words.
    enum Empty: Equatable {
        case elsewhere(agent: String, project: String, filter: String)   // Show all projects
        case recordingOff
        case nothing
        case noMatch
    }
    static func empty(projectFilter: String?, working: [SessionRow], recording: Bool, anyEvents: Bool) -> Empty {
        if let p = projectFilter,
           let w = working.first(where: { !$0.project.isEmpty && !ActivityFeed.inWorkspace($0.project, p) }) {
            return .elsewhere(agent: w.displayAgent, project: w.projectName, filter: (p as NSString).lastPathComponent)
        }
        if !recording { return .recordingOff }
        return anyEvents ? .noMatch : .nothing
    }

    /// "Recording started at 18:55; earlier activity wasn't kept." when a live
    /// session began before the first record Kai has.
    static func recordingLate(firstRecord: Double?, sessions: [SessionRow], now: Date = Date()) -> String? {
        guard let f = firstRecord, f > 0 else { return nil }
        let d = Date(timeIntervalSince1970: f)
        guard Calendar.current.isDate(d, inSameDayAs: now),
              sessions.contains(where: { $0.isActive && $0.isSession && $0.startedUtc > 0 && Double($0.startedUtc) < f - 60 })
        else { return nil }
        let fm = DateFormatter(); fm.dateFormat = "HH:mm"
        return "Recording started at \(fm.string(from: d)); earlier activity wasn't kept."
    }
}
