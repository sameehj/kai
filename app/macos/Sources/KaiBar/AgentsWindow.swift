// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// S5 — the Agents window: every agent, every session, and the permissions and
// pending decisions for each. Data comes from the read-only CLIs built in
// S1–S4 (`kai agents --json`, `kai sessions --json`) plus the live GrantManager.
// Agent-reported fields (the topic) are always labelled "reported by agent" and
// never drive a decision.
import SwiftUI
import KaiCore

// MARK: - CLI-backed rows

struct AgentRow: Decodable, Identifiable, Equatable {
    let name: String
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
}

struct SessionRow: Decodable, Identifiable, Equatable {
    let id: String
    let agent: String
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
    var state: String = "active"
    /// One session definition (libkai): working = a command or hook in the
    /// last 15 minutes; idle otherwise; ended is separate.
    var activity: String = "idle"
    var lastActiveUtc: Int = 0
    /// An IDE app is one row holding its workspaces.
    struct Workspace: Decodable, Equatable, Identifiable {
        let path: String
        var lastActiveUtc: Int = 0
        var activity: String = "idle"
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }
    var workspaces: [Workspace]? = nil
    var isActive: Bool { state == "active" }
    var isWorking: Bool { isActive && activity == "working" }
    var isSession: Bool { kind == "session" }
    var isIDE: Bool { workspaces != nil }
    var window: String { !tty.isEmpty ? tty : (hostApp.isEmpty ? "—" : hostApp) }
    var projectName: String {
        if let w = workspaces {
            // B1: count only what is known; "0 workspaces" on an active app misleads.
            return w.isEmpty ? (hostApp.isEmpty ? displayAgent : hostApp)
                             : "\(w.count) workspace\(w.count == 1 ? "" : "s")"
        }
        let base = project.isEmpty ? "—" : (project as NSString).lastPathComponent
        return nameSuffix.isEmpty ? base : "\(base) · \(nameSuffix)"
    }
    /// B1: set by AgentsModel when two live sessions would read the same: the
    /// topic, else the terminal, else the start time.
    var nameSuffix: String = ""
    enum CodingKeys: String, CodingKey {
        case id, agent, topic, topicReportedByAgent, project, hostApp, startedUtc, endedUtc, childCount,
             source, kind, tty, enforcement, state, activity, lastActiveUtc, workspaces
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
        return isWorking ? "active \(d) ago" : "idle \(d)"
    }
    /// Never say "protected": the label comes straight from observed enforcement.
    var enforcementShort: String {
        if enforcement.hasPrefix("Enforced: Files and Internet") { return "Files + Internet" }
        if enforcement.hasPrefix("Enforced: Internet") { return "Internet only" }
        if enforcement.hasPrefix("Enforced: Files") { return "Files only" }
        return "seen only"
    }
    /// When the session's pause expires (nil if not paused), for "Paused until HH:MM".
    var pausedUntil: Date? {
        let t = id.withCString { kai_session_pause_until($0) }
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }
    var pausedUntilLabel: String {
        guard let d = pausedUntil else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

@MainActor
final class AgentsModel: ObservableObject {
    /// ONE session store for the popover and the Agent Control window: the
    /// window renders what the popover already has, then refreshes quietly.
    static let shared = AgentsModel()
    @Published private(set) var agents: [AgentRow] = []
    @Published private(set) var sessions: [SessionRow] = []
    /// False until the first refresh lands: show placeholders, never a false
    /// "No agent sessions".
    @Published private(set) var loaded = false
    private var refreshing = false
    enum Filter: String, CaseIterable, Identifiable { case running, ended, all; var id: String { rawValue } }
    @Published var filter: Filter = .running
    @Published var agentFilter: String? = nil
    private var timer: Timer?

    /// Only real interactive sessions (not daemons/nested/orphans).
    var interactiveSessions: [SessionRow] { sessions.filter { $0.isSession } }
    /// The three list sections; ended never mixes into the live ones.
    var workingNow: [SessionRow] { interactiveSessions.filter { $0.isWorking }.sorted { $0.lastActiveUtc > $1.lastActiveUtc } }
    var idle: [SessionRow] { interactiveSessions.filter { $0.isActive && !$0.isWorking }.sorted { $0.lastActiveUtc > $1.lastActiveUtc } }
    var endedToday: [SessionRow] { interactiveSessions.filter { !$0.isActive }.sorted { $0.endedUtc > $1.endedUtc } }
    var backgroundServices: [SessionRow] { sessions.filter { $0.kind == "background service" } }
    /// Sessions currently paused (Kai skipped for them, auto-resuming).
    var pausedSessions: [SessionRow] {
        let now = Int64(Date().timeIntervalSince1970)
        return interactiveSessions.filter { s in
            s.id.withCString { kai_session_paused($0, now) } != 0
        }
    }

    init() {
        Task { await refresh() }
        // The session scan is cheap now, but this model is always alive behind
        // the menu bar; poll infrequently so it costs almost nothing at rest.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    /// One CLI call for both (kai snapshot --json); overlapping refreshes skip.
    private struct Snapshot: Decodable { let sessions: [SessionRow]; let agents: [AgentRow] }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let s = await KaiCLI.decode(Snapshot.self, ["snapshot", "--json"]) {
            var rows = s.sessions
            // Two live sessions with the same agent + project: tell them apart.
            let keyOf = { (r: SessionRow) in r.displayAgent + "|" + r.project }
            let dup = Dictionary(grouping: rows.filter { $0.isActive && $0.workspaces == nil }, by: keyOf)
                .filter { $0.value.count > 1 }
            for i in rows.indices where rows[i].isActive && dup[keyOf(rows[i])] != nil {
                let r = rows[i]
                rows[i].nameSuffix = !r.topic.isEmpty ? String(r.topic.prefix(30))
                                   : !r.tty.isEmpty ? r.tty : "started \(r.startedClock)"
            }
            if rows != sessions { sessions = rows }
            agents = s.agents
            loaded = true
        }
    }

    /// Sessions after the current filters, needs-attention first (active before
    /// ended), then newest-started first.
    func visibleSessions(needsAttention: (SessionRow) -> Bool) -> [SessionRow] {
        sessions.filter { s in
            (filter == .all || (filter == .running && s.isActive) || (filter == .ended && !s.isActive))
            && (agentFilter == nil || s.agent == agentFilter)
        }.sorted { a, b in
            let na = needsAttention(a), nb = needsAttention(b)
            if na != nb { return na }               // needs-attention first
            if a.isActive != b.isActive { return a.isActive }  // active before ended
            return a.startedUtc > b.startedUtc       // newest first
        }
    }
}

// MARK: - Window

struct AgentsWindow: View {
    @ObservedObject private var model = AgentsModel.shared
    @StateObject private var grants = GrantManager()
    @State private var selected: String?

    private func needsAttention(_ s: SessionRow) -> Bool {
        s.isActive && !grants.pending.isEmpty       // interim: any pending decision flags active sessions
    }

    var body: some View {
        NavigationSplitView {
            AgentsSidebar(model: model)
                .frame(minWidth: 210)
        } detail: {
            HSplitView {
                sessionsList.frame(minWidth: 320)
                detailPane.frame(minWidth: 320)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task { await model.refresh() }
    }

    private var sessionsList: some View {
        let rows = model.visibleSessions(needsAttention: needsAttention)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Picker("", selection: $model.filter) {
                    Text("Running").tag(AgentsModel.Filter.running)
                    Text("Ended").tag(AgentsModel.Filter.ended)
                    Text("All").tag(AgentsModel.Filter.all)
                }.pickerStyle(.segmented).fixedSize()
            }.padding(10)
            if !grants.pending.isEmpty || !grants.pendingPolicy.isEmpty {
                ScrollView { ApprovalsSection(manager: grants).padding(.horizontal, 10) }
                    .frame(maxHeight: 180)
                Divider()
            }
            List(rows, selection: $selected) { s in
                SessionRowView(session: s, needsYou: needsAttention(s)).tag(s.id)
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let id = selected, let s = model.sessions.first(where: { $0.id == id }) {
            SessionDetail(session: s, grants: grants)
        } else {
            VStack { Spacer(); Text("Select a session").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }
}

struct AgentsSidebar: View {
    @ObservedObject var model: AgentsModel
    var body: some View {
        List {
            Section("Agents") {
                ForEach(model.agents) { a in
                    Button { model.agentFilter = (model.agentFilter == a.name) ? nil : a.name } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(a.name).fontWeight(.medium)
                                Spacer()
                                if a.activeSessions > 0 { Text("\(a.activeSessions)").foregroundStyle(.secondary) }
                            }
                            Text("\(a.hooksLabel) · \(a.wallRecognized ? "recognized" : "not recognized")")
                                .font(.caption).foregroundStyle(a.hooks == "failing" ? .orange : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.agentFilter == a.name ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            Section {
                // Unattributed processes (detached / unverifiable lineage) are
                // surfaced here; wiring the live count is a follow-up (needs the
                // ES wall to report agent-tree processes it put in no session).
                Text("Unattributed processes").font(.caption).foregroundStyle(.secondary)
                Text("Shown here when detected (coming soon)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SessionRowView: View {
    let session: SessionRow
    let needsYou: Bool
    var body: some View {
        HStack(spacing: 8) {
            if needsYou { Circle().fill(Color.orange).frame(width: 7, height: 7) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.displayAgent).fontWeight(.medium)
                    Text(session.enforcementShort).font(.caption2)
                        .foregroundStyle(session.enforcementShort == "Files + Internet" ? .green
                                         : session.enforcementShort == "seen only" ? .secondary : .orange)
                    if !session.isActive { Text("ended").font(.caption2).foregroundStyle(.secondary) }
                }
                if !session.topic.isEmpty {   // hook-reported topic, or hidden
                    Text(session.topic).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {          // project once, window/tab, time
                    Text(session.projectName)
                    Text("· \(session.window)")
                    if !session.activeLabel.isEmpty { Text("· \(session.activeLabel)") }
                }.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }.padding(.vertical, 2)
    }
}

struct SessionDetail: View {
    let session: SessionRow
    @ObservedObject var grants: GrantManager
    private var sessionGrants: [ActiveGrant] { grants.grants.filter { $0.session_id == session.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(session.displayAgent).font(.title2).fontWeight(.semibold)
                    Spacer()
                    if session.isActive {
                        // Item 4: pause acts through the storage wall by ES session
                        // id. A scan-only session (no ES session) or one the storage
                        // wall doesn't cover can't be paused.
                        let storageCovered = session.source == "es" &&
                            session.enforcement.hasPrefix("Enforced: Files")
                        if storageCovered {
                            PauseControl(state: grants.pauseState(session.id), until: grants.pauseEnds(session.id),
                                         pause: { grants.pauseSession(session.id, minutes: 15) },
                                         resume: { grants.pauseSession(session.id, minutes: 0) },
                                         extend: { grants.extendPause(session.id) })
                                .frame(maxWidth: 360)
                        } else {
                            // The wall keys sessions to the agent root (Phase A item
                            // 5), so this shows only until the wall first sees the
                            // session act; the global pause always works meanwhile.
                            Button("Pause Kai for all agents (15 min)") { grants.pauseAll(minutes: 15) }
                                .help("Pause isn't available for this session yet, so this pauses Kai "
                                      + "for every agent for 15 minutes, then resumes by itself.")
                        }
                    }
                }
                if !session.topic.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.topic)
                        Text("topic reported by agent").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Item 6/4: coverage disclosure (ide-extension, browser, or unverified).
                if let noteC = session.agent.withCString({ kai_agent_coverage_note($0) }) {
                    Text(String(cString: noteC)).font(.caption).foregroundStyle(.orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    detailRow("Enforcement", session.enforcement.isEmpty ? "—" : session.enforcement)
                    detailRow(session.isIDE ? "Workspaces" : "Project",
                              session.isIDE ? (session.workspaces ?? []).map { "\($0.name) (\($0.activity))" }
                                                  .joined(separator: ", ")
                                            : session.project)
                    detailRow("Window", session.window)
                    detailRow("Host app", session.hostApp.isEmpty ? "-" : session.hostApp)
                    detailRow("Started", session.startedClock)
                    detailRow("Activity", session.activeLabel.isEmpty ? session.state : session.activeLabel)
                    detailRow("Processes", "\(session.childCount + 1)")
                    detailRow("State", session.state)
                    detailRow("Session id", session.id)
                }.font(.callout)

                Text("Permissions").font(.headline)
                if sessionGrants.isEmpty {
                    Text("No permissions for this session.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(sessionGrants) { g in
                        HStack {
                            Text("\(g.opLabel) · \(g.scopeLabel)\(g.signed ? "" : " (unsigned)")").font(.caption)
                            Spacer()
                            Text(g.resource).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                            Button("Revoke") { grants.revoke(g) }
                        }
                    }
                }
                Spacer()
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func detailRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}
