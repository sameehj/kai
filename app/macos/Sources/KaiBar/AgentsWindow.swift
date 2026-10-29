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

// AgentRow and SessionRow (and their tolerant decoding) live in Sessions.swift,
// Foundation-only so the app tests decode the real `kai snapshot --json`.
extension SessionRow {
    /// The topic without stray whitespace or line breaks (an empty-looking
    /// topic drew an empty first line).
    var topicLine: String {
        var buf = [CChar](repeating: 0, count: 512)
        kai_topic_clean(topic, &buf, buf.count)
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Why the session list couldn't be read (binary, exit code, duration,
    /// decode error); nil when it was. Shown instead of a false "0 working".
    @Published private(set) var sourceError: String?
    /// Rows skipped because they didn't decode (the rest still show).
    @Published private(set) var skippedRows: [String] = []
    var countKnown: Bool { loaded && sourceError == nil }

    /// One CLI call for both (kai snapshot --json); overlapping refreshes skip.
    /// Decoded row by row (SessionSnapshot): one bad row never empties the list.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let exe = KaiCLI.executable?.path ?? "kai (not found)"
        let t0 = Date()
        let r = await KaiCLI.run(["snapshot", "--json"])
        let took = String(format: "%.2fs", Date().timeIntervalSince(t0))
        guard r.ok else {
            fail("\(exe) snapshot --json exited \(r.code) after \(took): \(r.message)")
            return
        }
        let snap: SessionSnapshot
        do { snap = try SessionSnapshot.decode(Data(r.out.utf8)) }
        catch {
            fail("\(exe) snapshot --json (exit 0, \(took)) couldn't be read: \(error)")
            return
        }
        if !snap.failures.isEmpty { NSLog("Kai: skipped %d session/agent rows: %@", snap.failures.count, snap.failures.joined(separator: "; ")) }
        if skippedRows != snap.failures { skippedRows = snap.failures }
        if sourceError != nil { sourceError = nil }
        do {
            let s = snap
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

    /// The source failed: say so (and log it); the count isn't known.
    private func fail(_ why: String) {
        NSLog("Kai: %@", why)
        if sourceError != why { sourceError = why }
        loaded = true
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
                    if let i = InfoText.coverage(session.enforcementShort) { InfoButton(text: i) }
                    if !session.isActive { Text("ended").font(.caption2).foregroundStyle(.secondary) }
                }
                if !session.topicLine.isEmpty {   // hook-reported topic, or hidden
                    Text(session.topicLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        if storageCovered && DevFlags.perSessionPause {
                            PauseControl(state: grants.pauseState(session.id), until: grants.pauseEnds(session.id),
                                         pause: { grants.pauseSession(session.id, minutes: 15) },
                                         resume: { grants.pauseSession(session.id, minutes: 0) },
                                         extend: { grants.extendPause(session.id) })
                                .frame(maxWidth: 360)
                        }   // no global pause here: it lives in the popover (Pause Kai · 15 min)
                    }
                }
                if !session.topicLine.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.topicLine)
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
