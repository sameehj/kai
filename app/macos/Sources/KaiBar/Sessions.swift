// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The rows `kai snapshot --json` returns (sessions and agents), decoded
// tolerantly: every field has a default when missing, unknown fields are
// ignored, an unknown activity or state reads "unknown", and one bad row is
// skipped (and counted) instead of emptying the list. Foundation only, so the
// app tests decode the real output of the built `kai` (tests/app).
import Foundation

/// Decodes each element on its own: a row that fails is dropped and counted.
struct LossyList<T: Decodable>: Decodable {
    var items: [T] = []
    var failures: [String] = []
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            do { items.append(try c.decode(T.self)) }
            catch {
                failures.append("\(T.self) #\(c.currentIndex): \(error)")
                _ = try? c.decode(Skip.self)   // step past the bad element
            }
        }
    }
    /// Accepts any JSON value without reading it, so the cursor always moves on.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ k: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
}

struct AgentRow: Decodable, Identifiable, Equatable {
    var name: String
    var hooks: String = "n/a"
    var wallRecognized: Bool = false
    var activeSessions: Int = 0
    var detail: String? = nil
    var id: String { name }
    var hooksLabel: String {
        switch hooks {
        case "installed": return "hooks installed"
        case "missing": return "hooks missing"
        case "failing": return "hooks failing"
        case "not found": return "not installed"
        default: return "no Kai hooks"
        }
    }
    enum CodingKeys: String, CodingKey { case name, hooks, wallRecognized, activeSessions, detail }
    init(name: String) { self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)   // a row without a name is a bad row
        hooks = c.value(.hooks, "n/a")
        wallRecognized = c.value(.wallRecognized, false)
        activeSessions = c.value(.activeSessions, 0)
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
    }
}

struct SessionRow: Decodable, Identifiable, Equatable {
    var id: String
    var agent: String
    var topic: String = ""
    var topicReportedByAgent: Bool = true
    var project: String = ""
    var hostApp: String = ""
    var startedUtc: Int = 0
    var endedUtc: Int = 0
    var childCount: Int = 0
    var source: String = "es"
    var kind: String = "session"     // session | nested | background service | idle...
    var tty: String = ""
    var enforcement: String = ""
    var state: String = "active"     // active | ended | unknown
    /// One session definition (libkai): working = a call in progress or an
    /// event in the last 15 minutes; idle otherwise; "unknown" for a value
    /// this app doesn't know.
    var activity: String = "idle"
    var lastActiveUtc: Int = 0
    /// An IDE app is one row holding its workspaces.
    struct Workspace: Decodable, Equatable, Identifiable {
        var path: String
        var lastActiveUtc: Int = 0
        var activity: String = "idle"
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        enum CodingKeys: String, CodingKey { case path, lastActiveUtc, activity }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            lastActiveUtc = c.value(.lastActiveUtc, 0)
            activity = SessionRow.known(c.value(.activity, "idle"), ["working", "idle"])
        }
    }
    var workspaces: [Workspace]? = nil
    /// B1: set by AgentsModel when two live sessions would read the same.
    var nameSuffix: String = ""

    static func known(_ v: String, _ values: Set<String>) -> String { values.contains(v) ? v : "unknown" }

    enum CodingKeys: String, CodingKey {
        case id, agent, topic, topicReportedByAgent, project, hostApp, startedUtc, endedUtc, childCount,
             source, kind, tty, enforcement, state, activity, lastActiveUtc, workspaces
    }
    init(id: String, agent: String) { self.id = id; self.agent = agent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)       // without an id or agent it's a bad row
        agent = try c.decode(String.self, forKey: .agent)
        topic = c.value(.topic, "")
        topicReportedByAgent = c.value(.topicReportedByAgent, true)
        project = c.value(.project, "")
        hostApp = c.value(.hostApp, "")
        startedUtc = c.value(.startedUtc, 0)
        endedUtc = c.value(.endedUtc, 0)
        childCount = c.value(.childCount, 0)
        source = c.value(.source, "es")
        kind = c.value(.kind, "session")
        tty = c.value(.tty, "")
        enforcement = c.value(.enforcement, "")
        state = SessionRow.known(c.value(.state, "active"), ["active", "ended"])
        activity = SessionRow.known(c.value(.activity, "idle"), ["working", "idle"])
        lastActiveUtc = c.value(.lastActiveUtc, 0)
        // a workspace list that doesn't decode keeps the row (as an app with unknown workspaces)
        workspaces = (try? c.decodeIfPresent(LossyList<Workspace>.self, forKey: .workspaces))??.items
    }

    /// Only an explicit "ended" is ended: an unknown state stays listed (as unknown).
    var isActive: Bool { state != "ended" }
    var isWorking: Bool { isActive && activity == "working" }
    var isSession: Bool { kind == "session" }
    var isIDE: Bool { workspaces != nil }
    var window: String { !tty.isEmpty ? tty : (hostApp.isEmpty ? "—" : hostApp) }
    /// The project (or app) without the suffix that tells duplicates apart.
    var projectBase: String {
        if let w = workspaces {
            return w.isEmpty ? (hostApp.isEmpty ? displayAgent : hostApp)
                             : "\(w.count) workspace\(w.count == 1 ? "" : "s")"
        }
        return project.isEmpty ? "—" : (project as NSString).lastPathComponent
    }
    var projectName: String {
        if let w = workspaces {
            // B1: count only what is known; "0 workspaces" on an active app misleads.
            return w.isEmpty ? (hostApp.isEmpty ? displayAgent : hostApp)
                             : "\(w.count) workspace\(w.count == 1 ? "" : "s")"
        }
        let base = project.isEmpty ? "—" : (project as NSString).lastPathComponent
        return nameSuffix.isEmpty ? base : "\(base) · \(nameSuffix)"
    }
    /// Proper product names, not the lowercase classifier.
    var displayAgent: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini CLI"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
    /// Start time: date when it wasn't today (e.g. "Oct 17"), else "HH:mm".
    var startedClock: String {
        guard startedUtc > 0 else { return "" }
        let d = Date(timeIntervalSince1970: TimeInterval(startedUtc))
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d"
        return f.string(from: d)
    }
    /// Duration = time since the agent was last active (not since the window
    /// opened): "active 2m ago", "idle 3h 10m". "8d 2h" never "190h 8m".
    var activeLabel: String {
        guard isActive else { return "" }
        guard lastActiveUtc > 0 else { return "no activity seen" }
        let s = max(0, Int(Date().timeIntervalSince1970) - lastActiveUtc)
        let d = s >= 86400 ? "\(s / 86400)d \((s % 86400) / 3600)h"
              : s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : s >= 60 ? "\(s / 60)m" : "\(s)s"
        if activity == "unknown" { return "activity unknown · last seen \(d) ago" }
        return isWorking ? "active \(d) ago" : "idle \(d)"
    }
    /// Never say "protected": the label comes straight from observed enforcement.
    var enforcementShort: String {
        if enforcement.hasPrefix("Enforced: Files and Internet") { return "Files + Internet" }
        if enforcement.hasPrefix("Enforced: Internet") { return "Internet only" }
        if enforcement.hasPrefix("Enforced: Files") { return "Files only" }
        return "seen only"
    }
}

/// `kai snapshot --json`: both lists, each decoded row by row.
struct SessionSnapshot: Decodable {
    var sessions: [SessionRow] = []
    var agents: [AgentRow] = []
    var failures: [String] = []
    enum CodingKeys: String, CodingKey { case sessions, agents }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(LossyList<SessionRow>.self, forKey: .sessions)   // no list at all = a failed source
        let a = (try? c.decodeIfPresent(LossyList<AgentRow>.self, forKey: .agents)) ?? nil
        sessions = s.items
        agents = a?.items ?? []
        failures = s.failures + (a?.failures ?? [])
    }
    static func decode(_ data: Data) throws -> SessionSnapshot {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SessionSnapshot.self, from: data)
    }
}
