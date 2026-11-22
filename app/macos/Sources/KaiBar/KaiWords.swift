// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5.1: the words several screens share, in one place so they can't drift:
//   - who stopped it: always "Kai stopped <agent>'s command" (Kai is the
//     subject; the agent never "stopped" anything),
//   - the Internet setting (Off · Watch · Watch + block my list) and what each
//     one honestly does,
//   - paths relative to the session's project ("outside project", temp
//     folders grouped),
//   - the popover's numbers and session lines, and the card's
//     "Recorded in Activity since …" line.
//
// Foundation only: compiled into the app tests with AuditLog.swift and
// NowModel.swift.
import Foundation

// MARK: - Who stopped it

enum StopWords {
    enum Kind: Equatable { case read, change, command, connection, prompt, mcp, request }

    static func kind(op: String) -> Kind {
        switch op {
        case "read": return .read
        case "edit", "write": return .change
        case "command": return .command
        case "mcp": return .mcp
        case "connect", "connection": return .connection
        default: return .request
        }
    }

    static func kind(_ e: AuditEvent) -> Kind {
        if e.isPrompt { return .prompt }
        if e.isNetwork { return .connection }
        switch e.actionLabel {
        case "File read": return .read
        case "File edit": return .change
        case "Command": return .command
        case "Tool call": return .mcp
        default: return .request
        }
    }

    /// "Kai stopped Claude Code reading .env", "Kai stopped Claude Code's
    /// command", "Kai stopped Cursor's connection to paste.example.org".
    /// `object` is a file name or host, never a full path or command line.
    static func line(agent: String, kind: Kind, object: String? = nil) -> String {
        let who = agent.isEmpty ? "an agent" : agent
        let obj = object.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .read: return "Kai stopped \(who) reading " + (obj ?? "a file")
        case .change: return "Kai stopped \(who) changing " + (obj ?? "a file")
        case .command: return "Kai stopped \(possessive(who)) command"
        case .connection: return "Kai stopped \(possessive(who)) connection" + (obj.map { " to \($0)" } ?? "")
        case .prompt: return "Kai stopped \(possessive(who)) prompt"
        case .mcp: return "Kai stopped \(possessive(who)) MCP call"
        case .request: return "Kai stopped \(possessive(who)) request"
        }
    }

    static func line(_ e: AuditEvent) -> String {
        let k = kind(e)
        let obj: String?
        switch k {
        case .read, .change: obj = e.excerpt.map { ($0 as NSString).lastPathComponent }
        case .connection: obj = e.blockedSite ?? e.target
        default: obj = nil
        }
        return line(agent: e.agentName, kind: k, object: obj)
    }

    static func possessive(_ name: String) -> String { name.hasSuffix("s") ? name + "'" : name + "'s" }
}

extension AuditEvent {
    /// 0.5.1: a connection Kai refused because the site is on the user's
    /// block list ("blocked site paste.example.org"). The site, else nil.
    var blockedSite: String? {
        guard isNetwork, isBlock, rawDetail.hasPrefix("blocked site ") else { return nil }
        let s = String(rawDetail.dropFirst("blocked site ".count)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

// MARK: - The Internet setting

enum InternetMode: String, CaseIterable, Identifiable, Equatable {
    case off, watch, blocklist
    var id: String { rawValue }

    /// The app sets this from the policy and the extension's state, like
    /// AuditEvent.filesEnforcing; the Foundation-only words below read it.
    static var current: InternetMode = .off
    /// S5 gate: "Watch + block my list" is offered only when it was verified
    /// on a real Mac for this release (see the release notes). The engine
    /// code stays in either way.
    static let blocklistOffered = true

    /// From the policy's `egress` switch and whether the extension runs.
    static func from(egress: String?, extensionOn: Bool) -> InternetMode {
        guard extensionOn else { return .off }
        switch egress ?? "log" {
        case "off": return .off
        case "blocklist": return blocklistOffered ? .blocklist : .watch
        default: return .watch   // "log"; strict "block" is clamped to Watch in release builds
        }
    }

    /// The policy's `egress` value for this choice.
    var egress: String {
        switch self {
        case .off: return "off"
        case .watch: return "log"
        case .blocklist: return "blocklist"
        }
    }

    static var offered: [InternetMode] { blocklistOffered ? [.off, .watch, .blocklist] : [.off, .watch] }

    var label: String {
        switch self {
        case .off: return "Off"
        case .watch: return "Watch"
        case .blocklist: return "Watch + block my list"
        }
    }

    /// The page subtitle, true for the state it is shown in.
    var subtitle: String {
        switch self {
        case .off: return "Off. Turn on Watch to record where agents connect."
        case .watch: return "Watch: Kai records where agents connect. Nothing is blocked."
        case .blocklist: return "Watch + block my list: Kai records where agents connect and refuses their direct "
            + "connections to the sites on your list."
        }
    }

    /// One line under the control.
    var detail: String {
        switch self {
        case .off: return "Kai doesn't record agent connections."
        case .watch: return "Records the connections Kai observes. Blocks nothing."
        case .blocklist: return "Records the connections Kai observes, and refuses new agent connections to your "
            + "blocked sites. Everything else is only recorded."
        }
    }

    /// The limit said under connection answers and rows.
    var connectionLimit: String {
        switch self {
        case .blocklist: return "Kai refused only connections to sites on your block list; the rest were only "
            + "recorded. A connection doesn't show what was sent."
        default: return "Internet is Watch only: nothing was blocked, and a connection doesn't show what was sent."
        }
    }

    /// The evidence a connection row names.
    var evidence: String { self == .blocklist ? "Network wall (Watch + block my list)" : "Network wall (Watch only)" }

    /// Verbatim limit line under the block list (release brief §3).
    static let limitLine = "Kai refuses agents' direct connections to these sites. An agent could still reach "
        + "them another way, for example through a proxy or a site that isn't on your list."
}

/// The block list's starter set, offered once and unchecked.
enum BlockStarter {
    /// Common paste and file-sharing sites.
    static let sharing = ["pastebin.com", "paste.ee", "hastebin.com", "dpaste.org", "ghostbin.site", "0x0.st",
                          "transfer.sh", "file.io", "wetransfer.com", "temp.sh"]
    /// The telemetry hosts Kai knows (the same list as kai_host_is_telemetry in src/net.c).
    static let telemetry = ["sentry.io", "datadoghq.com", "datadoghq.eu", "statsig.com", "statsigapi.net",
                            "featuregates.org", "segment.io", "segment.com", "mixpanel.com", "amplitude.com",
                            "posthog.com", "honeycomb.io", "bugsnag.com", "newrelic.com", "launchdarkly.com",
                            "app-measurement.com", "metrics.cursor.sh"]

    /// Is host (or a parent domain) on the list?
    static func covers(_ list: [String], _ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return list.contains { e in
            let e = e.lowercased()
            return h == e || h.hasSuffix("." + e)
        }
    }

    /// A telemetry host the user put on the block list: "Blocked by Kai (your
    /// list)"; otherwise the agent's own setting turned it off.
    static func telemetryWords(agent: String, hosts: [String], blocked: [String]) -> String {
        if hosts.contains(where: { covers(blocked, $0) }) { return "Blocked by Kai (your list)" }
        return "Turned off in \(StopWords.possessive(agent)) own settings"
    }

    /// A value typed into "Blocked sites": a host (www. and a scheme or path
    /// removed), lower case; nil when it isn't one.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !s.isEmpty, s.count <= 253 else { return nil }
        let ok = s.allSatisfy { $0.isLetter || $0.isNumber || "-._:[]/".contains($0) }
        return ok ? s : nil
    }

    /// A plain host (any port) belongs in the shared list with `kai block`;
    /// an address, range or host:port goes in the policy's egress_block lines.
    static func isPlainHost(_ s: String) -> Bool {
        !s.contains(":") && !s.contains("/") && s.contains(".") && !s.allSatisfy { $0.isNumber || $0 == "." }
    }
}

// MARK: - Paths

enum PathWords {
    /// Temp and scratch folders: grouped, never listed path by path.
    static func isTemp(_ path: String) -> Bool {
        let p = path
        return p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/var/folders/")
            || p.hasPrefix("/private/var/folders/") || p.contains("/scratchpad/") || p.hasSuffix("/scratchpad")
    }

    enum Shown: Equatable {
        case inProject(String)        // "src/app.tsx"
        case outside(String)          // file name only; the full path is in the detail sheet
        case temp(String)             // file name; grouped as "tmp · 3 files"
    }

    static func shown(_ path: String, project: String?) -> Shown {
        if isTemp(path) { return .temp((path as NSString).lastPathComponent) }
        if let w = project, !w.isEmpty, w != "/" {
            if path == w { return .inProject((w as NSString).lastPathComponent) }
            if path.hasPrefix(w + "/") { return .inProject(String(path.dropFirst(w.count + 1))) }
            if path.hasPrefix("/") { return .outside((path as NSString).lastPathComponent) }
        }
        if path.hasPrefix("/") { return .outside((path as NSString).lastPathComponent) }
        return .inProject(path)   // already relative
    }

    /// The row text: "src/app.tsx", "outside project · id_rsa.pub", "tmp · out.txt".
    static func text(_ path: String, project: String?) -> String {
        switch shown(path, project: project) {
        case .inProject(let p): return p
        case .outside(let n): return "outside project · " + n
        case .temp(let n): return "tmp · " + n
        }
    }
}

// MARK: - Plain labels (Activity)

enum EventWords {
    /// "Agent asked to read" / "write" / "run"; "Seen" for connections;
    /// "Stopped" for Kai's decisions. The evidence level stays in the sheet.
    static func label(_ k: TimelineEvent.Kind, op: String = "") -> String {
        switch k {
        case .file: return op == "read" ? "Agent asked to read" : "Agent asked to write"
        case .command: return "Agent asked to run"
        case .tool: return "Agent asked to use a tool"
        case .connection: return "Seen"
        case .stop: return "Stopped"
        }
    }

    /// The evidence level behind a label (requested / tool-reported / confirmed / unknown).
    static func evidenceLevel(_ k: TimelineEvent.Kind) -> String {
        switch k {
        case .file, .command, .tool: return "Requested (the agent's hook reported the request before the tool ran)"
        case .connection: return "Observed by Kai's network extension"
        case .stop: return "Confirmed (Kai's own decision)"
        }
    }
}

// MARK: - Numbers (popover, Now card)

struct TodayNumbers: Equatable {
    var actions: Int
    var stops: Int
    var connections: Int?

    /// "Today: 312 actions · 5 stops · 14 connections" (connections only
    /// while Internet watching is on).
    var parts: [String] {
        var p = ["Today: " + ActivityFeed.n(actions, "action"), ActivityFeed.n(stops, "stop")]
        if let c = connections { p.append(ActivityFeed.n(c, "connection")) }
        return p
    }
    var text: String { parts.joined(separator: " · ") }
}

enum SessionLine {
    /// The card's main count: the largest reported one ("261 commands").
    static func mainCount(_ c: NowCard) -> CardCount? {
        c.counts.filter { $0.kind != .stops && $0.notReportedBy == nil && ($0.value ?? 0) > 0 }
            .max { ($0.value ?? 0) < ($1.value ?? 0) }
    }

    /// "Ran a command · 6 min ago · 261 commands · 5 stops": at most two counts.
    static func text(_ c: NowCard, now: Date) -> String? {
        var parts: [String] = []
        if let l = c.lastLine(now: now) { parts.append(l) }
        if let m = mainCount(c) { parts.append(m.text) }
        let stops = c.counts.first { $0.kind == .stops }?.value ?? 0
        if stops > 0 { parts.append(ActivityFeed.n(stops, "stop")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What Activity holds for a session, in the card's own numbers. The card
/// and the Activity group header both read this, so they can't disagree.
struct RecordedSummary: Equatable {
    var files: Int
    var commands: Int
    var tools: Int
    var since: Double

    static func of(_ a: SessionActivity?) -> RecordedSummary? {
        guard let a, a.first > 0 else { return nil }
        let c = a.counts
        return RecordedSummary(files: c.read + c.edit + c.write, commands: c.command, tools: c.mcp + c.tool,
                               since: a.first)
    }

    /// "4 file actions, 12 commands" (zero counts left out).
    var countsText: String {
        var p: [String] = []
        if files > 0 { p.append(ActivityFeed.n(files, "file action")) }
        if commands > 0 { p.append(ActivityFeed.n(commands, "command")) }
        if tools > 0 { p.append(ActivityFeed.n(tools, "tool call")) }
        return p.isEmpty ? "nothing yet" : p.joined(separator: ", ")
    }

    /// "Recorded in Activity since 16:17: 4 file actions, 12 commands."
    var line: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "Recorded in Activity since \(f.string(from: Date(timeIntervalSince1970: since))): \(countsText)."
    }

    /// The muted line shows only when the card's numbers cover more than
    /// Activity does: stops counted from Kai's decisions since the session
    /// started, while recording began later.
    static func needsLine(card: NowCard) -> Bool {
        guard let r = of(card.activity) else { return false }
        let started = Double(card.session.startedUtc)
        let lateStart = started > 0 && r.since > started + 60
        let auditStops = card.stopCount > (card.activity?.stops ?? 0)
        return lateStart || auditStops
    }
}
