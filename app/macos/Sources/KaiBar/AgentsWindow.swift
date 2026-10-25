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
    var state: String = "active"
    var isActive: Bool { state == "active" }
}

@MainActor
final class AgentsModel: ObservableObject {
    @Published private(set) var agents: [AgentRow] = []
    @Published private(set) var sessions: [SessionRow] = []
    enum Filter: String, CaseIterable, Identifiable { case running, ended, all; var id: String { rawValue } }
    @Published var filter: Filter = .running
    @Published var agentFilter: String? = nil
    private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    func refresh() async {
        if let a = await KaiCLI.decode([AgentRow].self, ["agents", "--json"]) { agents = a }
        if let s = await KaiCLI.decode([SessionRow].self, ["sessions", "--json"]) { sessions = s }
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
    @StateObject private var model = AgentsModel()
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
                HStack {
                    Text(session.agent).fontWeight(.medium)
                    if !session.isActive { Text("ended").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(session.topic.isEmpty ? "(no topic reported)" : session.topic)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(session.project).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
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
                Text(session.agent).font(.title2).fontWeight(.semibold)
                if !session.topic.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.topic)
                        Text("topic reported by agent").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    detailRow("Project", session.project)
                    detailRow("Host app", session.hostApp.isEmpty ? "-" : session.hostApp)
                    detailRow("State", session.state)
                    detailRow("Session id", session.id)
                }.font(.callout)

                Text("Permissions").font(.headline)
                if sessionGrants.isEmpty {
                    Text("No active grants for this session.").font(.caption).foregroundStyle(.secondary)
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
