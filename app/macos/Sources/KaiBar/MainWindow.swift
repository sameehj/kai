// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.4: the Kai window (docs/design/kai_v11.html). Sidebar: Activity, Agents,
// Decisions, Ask Kai, with Settings pinned at the bottom. Toolbar: health on
// the left, the workspace in the middle, appearance and a menu on the right.
// A chat dock at the bottom (⌘K focuses it, ⌘J hides it).
import AppKit
import SwiftUI
import KaiCore

enum MainPage: String, CaseIterable, Identifiable {
    case activity, agents, decisions, ask, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: return "Activity"
        case .agents: return "Agents"
        case .decisions: return "Decisions"
        case .ask: return "Ask Kai"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .activity: return "list.bullet.rectangle"
        case .agents: return "person.2"
        case .decisions: return "hand.raised"
        case .ask: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

/// Where the window is and what it shows; the popover and kai:// links drive it.
@MainActor
final class MainNav: ObservableObject {
    static let shared = MainNav()
    @Published var page: MainPage = .activity
    @Published var agentFilter: String? = nil
    @Published var filter: ActivityFilter = .all
    @Published var search = ""
    @Published var openItem: ActivityItem? = nil
    @Published var openDecision: AuditEvent? = nil
    /// The chosen workspace (a project path); nil = the most recently active.
    @Published var pickedWorkspace: String? = nil
    @Published var chatHidden = false
    @Published var focusChat = 0
    @Published var askContext: ActivityItem? = nil

    func show(_ p: MainPage) { page = p }
    func showActivity(agent: String?) { agentFilter = agent; filter = .all; search = ""; page = .activity }
    func ask(about item: ActivityItem) {
        openItem = nil
        askContext = item
        chatHidden = false
        focusChat += 1
    }
}

/// What the Kai window reads beyond AppModel and AgentsModel: the recorder's
/// groups and `kai why` per decision.
@MainActor
final class KaiRecords: ObservableObject {
    static let shared = KaiRecords()
    @Published private(set) var groups: ActivityGroups? = nil
    @Published private(set) var why: [String: WhyRecord] = [:]
    @Published private(set) var loadedWorkspace: String? = nil

    func refresh(workspace: String?) async {
        var args = ["activity", "--json", "--since", "24h"]
        if let w = workspace { args += ["--workspace", w] }
        let r = await KaiCLI.run(args)
        groups = r.ok ? ActivityGroups.parse(r.out) : nil
        loadedWorkspace = workspace
    }

    func why(_ id: String) async -> WhyRecord? {
        if let w = why[id] { return w }
        let r = await KaiCLI.run(["why", id, "--json"])
        guard r.ok, let w = WhyRecord.parse(r.out) else { return nil }
        why[id] = w
        return w
    }
}

/// The workspaces Kai knows from sessions, most recently active first.
enum Workspaces {
    static func list(_ sessions: [SessionRow]) -> [(path: String, last: Int)] {
        var best: [String: Int] = [:]
        for s in sessions {
            if !s.project.isEmpty, s.project != "/" { best[s.project] = max(best[s.project] ?? 0, s.lastActiveUtc, s.startedUtc) }
            for w in s.workspaces ?? [] { best[w.path] = max(best[w.path] ?? 0, w.lastActiveUtc) }
        }
        let home = NSHomeDirectory()
        return best.filter { $0.key != home }.map { ($0.key, $0.value) }.sorted { $0.last > $1.last }
    }
    static func name(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "All workspaces" }
}

/// The header: the most important problem wins. One agent that isn't
/// connected never reads as "all checks are off".
struct HeaderState: Equatable {
    enum Tone { case ok, attention, off }
    var text: String
    var tone: Tone
    var detail: String? = nil

    @MainActor
    static func make(_ model: AppModel, _ agents: AgentsModel) -> HeaderState {
        if model.cliPath == nil || Lifecycle.programMissing {
            return HeaderState(text: "Kai is off", tone: .off, detail: "Kai's program is missing. Reinstall the Kai package.")
        }
        guard let rows = model.displayAgents(agents) else {
            if agents.sourceError != nil && Date().timeIntervalSince(AppModel.launchedAt) >= 5 {
                return HeaderState(text: "Kai can't list agents right now", tone: .attention, detail: agents.sourceError)
            }
            return HeaderState(text: "Checking…", tone: .ok)
        }
        let found = rows.filter(\.detected)
        if found.isEmpty { return HeaderState(text: "No supported agent found", tone: .attention) }
        if !found.contains(where: { $0.hooks == "installed" || $0.hooks == "untrusted" }) {
            return HeaderState(text: "Kai is off", tone: .off, detail: "No agent is connected to Kai.")
        }
        if GrantManager.shared.pauseState(nil) != Int32(KAI_PAUSE_NONE) {
            return HeaderState(text: "Kai is paused", tone: .attention, detail: "Checks resume by themselves.")
        }
        if let s = model.status {
            if !s.policy.ok { return HeaderState(text: "Kai's policy has an error", tone: .attention, detail: s.policy.error) }
            if let i = s.install, i.launcher == true, i.rootOnly == false {
                return HeaderState(text: "Kai's settings can be changed by other programs", tone: .attention,
                                   detail: "Reinstall the Kai package to put its program in an admin-only folder.")
            }
        }
        if let broken = found.first(where: { $0.hooks == "failing" }) {
            return HeaderState(text: "\(ActivityFeed.agentTitle(broken.name)) isn't connected", tone: .attention,
                               detail: "Kai's hook didn't answer a test request.")
        }
        if found.contains(where: { $0.hooks == "untrusted" }) {
            return HeaderState(text: "Codex needs one step", tone: .attention, detail: AutoConnect.codexTrustLine)
        }
        if let missing = found.first(where: { $0.hooks != "installed" }) {
            return HeaderState(text: "\(ActivityFeed.agentTitle(missing.name)) isn't connected", tone: .attention,
                               detail: "Kai doesn't check it until it's connected.")
        }
        let working = agents.workingNow.count
        return HeaderState(text: working > 0 ? "Connected · \(working) working" : "Connected", tone: .ok)
    }

    var color: Color {
        switch tone {
        case .ok: return Theme.muted
        case .attention: return Theme.amber
        case .off: return Theme.coral
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var records = KaiRecords.shared
    @ObservedObject private var ask = AskController.shared
    @AppStorage("appearance") private var appearance = "system"

    private var workspace: String? { nav.pickedWorkspace ?? Workspaces.list(agents.sessions).first?.path }
    private var header: HeaderState { HeaderState.make(model, agents) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if header.tone != .ok { banner }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !nav.chatHidden && nav.page != .settings {
                    Divider()
                    ChatDock(context: { makeContext() })
                }
            }
            .background(Theme.ink)
        }
        .navigationTitle("Kai")
        .toolbar { toolbar }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .tint(Theme.teal)
        .frame(minWidth: 860, minHeight: 600)
        .sheet(item: $nav.openItem) { item in
            EvidenceSheet(item: item).environmentObject(model)
        }
        .sheet(item: $nav.openDecision) { e in
            DecisionDetailSheet(event: e, workspace: workspace).environmentObject(model)
        }
        .background(shortcuts)
        .task(id: workspace) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await reload()
            }
        }
    }

    private func reload() async {
        await model.refresh()
        await agents.refresh()
        await records.refresh(workspace: workspace)
    }

    /// ⌘K focuses the chat, ⌘J hides or shows it.
    private var shortcuts: some View {
        HStack {
            Button("") { nav.chatHidden = false; nav.focusChat += 1 }.keyboardShortcut("k", modifiers: .command)
            Button("") { nav.chatHidden.toggle() }.keyboardShortcut("j", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) {
            ForEach([MainPage.activity, .agents, .decisions, .ask]) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 9) {
                Image("KaiLogo").resizable().frame(width: 26, height: 26).accessibilityHidden(true)
                Text("Kai").font(.system(size: 17, weight: .bold)).fixedSize()
                Spacer(minLength: 0)
                if !KaiInstance.isRelease { DevBadge().fixedSize() }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button { nav.page = .settings } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(nav.page == .settings ? Theme.teal.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Circle().fill(header.color).frame(width: 8, height: 8)
                Text(header.text).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .help(header.detail ?? header.text)
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .principal) {
            Menu {
                let list = Workspaces.list(agents.sessions)
                ForEach(list, id: \.path) { w in
                    Button {
                        nav.pickedWorkspace = w.path
                    } label: {
                        if w.path == workspace { Label(Workspaces.name(w.path), systemImage: "checkmark") }
                        else { Text(Workspaces.name(w.path)) }
                    }
                }
                if list.isEmpty { Text("No workspace from a session yet") }
                Divider()
                Button("Most recently active") { nav.pickedWorkspace = nil }
            } label: {
                Text(Workspaces.name(workspace)).font(.system(size: 15, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(workspace ?? "Workspaces come from agent sessions Kai saw")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .help("Appearance")
            Menu {
                Button("Refresh") { Task { await reload() } }
                Button(nav.chatHidden ? "Show chat" : "Hide chat") { nav.chatHidden.toggle() }
                Divider()
                Button("Pause Kai for 15 minutes") { GrantManager.shared.pauseAll(minutes: 15) }
                Button("Settings") { nav.page = .settings }
                Divider()
                Button("Quit Kai") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More")
        }
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: header.tone == .off ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(header.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(header.text).font(.system(size: 13, weight: .semibold))
                if let d = header.detail { Text(d).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if header.text.hasSuffix("isn't connected") || header.text == "Kai is off" { Button("Agents") { nav.page = .agents } }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(header.color.opacity(0.10))
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .activity: ActivityPageView(workspace: workspace)
        case .agents: AgentsPageView()
        case .decisions: DecisionsPageView(workspace: workspace)
        case .ask: AskKaiPage(context: { makeContext() })
        case .settings: SettingsView()
        }
    }

    // MARK: Ask Kai context: structured records only

    func makeContext() -> AskContext {
        let items = ActivityFeed.build(groups: records.groups, events: model.events, workspace: workspace,
                                       internetWatching: wall.isOn)
        let stops = ActivityFeed.stops(model.events, workspace: workspace)
        let askAgents = agents.agents.filter(\.detected).map { a -> AskAgent in
            let title = LiveCoverage.title(a.name)
            let running = agents.interactiveSessions.contains { $0.isActive && $0.displayAgent == title }
            let working = agents.workingNow.filter { $0.displayAgent == title }.count
            let untrusted = a.name == "codex" && a.hooks == "installed" && model.codexNeedsTrust
            return AskAgent(key: a.name, connected: a.hooks == "installed", running: running,
                            working: a.hooks == "installed" ? working : 0,
                            problem: a.hooks == "failing" ? a.detail : nil, untrusted: untrusted)
        }
        let internet: InternetState
        switch wall.state {
        case .on: internet = .on
        case .needsApproval, .allowFilter: internet = .needsApproval
        case .failed(let why): internet = .failed(why)
        default: internet = .off
        }
        let firsts = (records.groups?.groups ?? []).map(\.first).filter { $0 > 0 }
        let first = firsts.min().map { Date(timeIntervalSince1970: $0) }
        return AskContext(workspace: workspace, recording: model.recordingActivity || (records.groups?.recording ?? false),
                          internetWatching: wall.isOn, items: items, stops: stops, agents: askAgents,
                          why: records.why, focus: nav.askContext,
                          version: model.status?.version ?? "", commit: model.status?.commit ?? "",
                          internet: internet,
                          recordingFirst: first.flatMap { Calendar.current.isDateInToday($0) ? $0 : nil },
                          policyProblem: model.status.flatMap { $0.policy.ok ? nil : $0.policy.error },
                          paused: GrantManager.shared.pauseState(nil) != Int32(KAI_PAUSE_NONE))
    }
}

extension AppModel {
    var recordingActivity: Bool { policy?.switches["record_activity"] == "on" }
}

// MARK: - Shared row

struct RecordRow: View {
    let letter: String
    let title: String
    let subtitle: String
    var meta: String = ""
    var tone: Color = Theme.muted
    var askAbout: (() -> Void)? = nil
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                Text(letter).font(.system(size: 13, weight: .bold)).foregroundStyle(tone)
                    .frame(width: 34, height: 34)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if hover, let askAbout {
                    Button("Ask about this", action: askAbout).buttonStyle(.borderless)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.teal)
                }
                if !meta.isEmpty { Text(meta).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? Theme.raised.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RecordList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct PageColumn<Content: View>: View {
    let title: String
    let subtitle: Text
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 18, weight: .semibold)).padding(.bottom, 5)
                subtitle.font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 20)
                content
            }
            .padding(.horizontal, 38).padding(.vertical, 32)
            .frame(maxWidth: 890, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Activity

struct ActivityPageView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var records = KaiRecords.shared
    let workspace: String?

    private var all: [ActivityItem] {
        ActivityFeed.build(groups: records.groups, events: model.events, workspace: workspace,
                           internetWatching: wall.isOn)
    }
    private var shown: [ActivityItem] {
        all.filter { $0.matches(nav.filter) && $0.matches(search: nav.search) }
            .filter { nav.agentFilter == nil || $0.agentKey == nav.agentFilter }
    }

    var body: some View {
        PageColumn(title: "Activity",
                   subtitle: Text("What Kai recorded in ") + Text(Workspaces.name(workspace)).bold() + Text(" · Today")) {
            HStack(spacing: 12) {
                Picker("", selection: $nav.filter) {
                    ForEach(ActivityFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                if let a = nav.agentFilter {
                    Button { nav.agentFilter = nil } label: {
                        Label(ActivityFeed.agentTitle(a), systemImage: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Show all agents")
                }
                Spacer()
                TextField("Search activity", text: $nav.search).textFieldStyle(.roundedBorder).frame(width: 190)
            }
            .padding(.bottom, 13)
            if !model.recordingActivity && !(records.groups?.recording ?? false) { recordingOff }
            if shown.isEmpty {
                RecordList {
                    VStack(spacing: 6) {
                        Text("No matching recorded activity.").foregroundStyle(Theme.muted)
                        Text("No record doesn't mean nothing happened.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(28)
                }
            } else {
                RecordList {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider() }
                        RecordRow(letter: item.letter, title: item.title, subtitle: "\(item.agent) · \(item.detail)",
                                  meta: item.countText, tone: item.kind == .stop ? Theme.amber : Theme.muted,
                                  askAbout: { nav.ask(about: item) }) { open(item) }
                    }
                }
            }
            if !wall.isOn && nav.filter == .connections {
                Text("Connections appear when Internet watching is on (Settings → Internet).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }

    private func open(_ item: ActivityItem) {
        nav.openItem = item
    }

    private var recordingOff: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity recording is off").font(.system(size: 13, weight: .semibold))
                Text("Kai lists what it stopped. To also list the files agents read or changed and the commands "
                     + "they asked to run, turn on recording. It stays on this Mac for 7 days and never keeps "
                     + "file contents, arguments or full commands.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Turn on activity recording") { model.setSwitch("record_activity", "on") }
                .buttonStyle(LimeButtonStyle())
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border))
        .padding(.bottom, 14)
    }
}

/// One record's evidence: Outcome, Agent, Evidence source, Session, Scope,
/// up to four examples.
struct EvidenceSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = MainNav.shared
    @Environment(\.dismiss) private var dismiss
    let item: ActivityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 20, weight: .semibold))
                    Text(item.explanation).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Divider().padding(.vertical, 15)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                row("Outcome", item.outcome)
                row("Agent", item.agent)
                row("Evidence source", item.source)
                row("Session", item.session)
                row("Scope", item.scope)
                ForEach(Array(item.examples.prefix(4).enumerated()), id: \.offset) { i, ex in
                    row(i == 0 ? "Examples" : "", ex, mono: true)
                }
            }
            HStack {
                Spacer()
                Button("Ask about this") { nav.ask(about: item); nav.page = .ask }
                if item.kind == .stop, let e = model.events.first(where: { $0.id == item.eventID }) {
                    Button("Open decision") { nav.openItem = nil; DispatchQueue.main.async { nav.openDecision = e } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(26)
        .frame(width: 540)
    }

    @ViewBuilder private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Agents

struct AgentsPageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var agents = AgentsModel.shared
    @ObservedObject private var nav = MainNav.shared

    var body: some View {
        PageColumn(title: "Agents", subtitle: Text("Kai's connection to each agent on this Mac, and what it reports.")) {
            let rows = model.displayAgents(agents)
            let found = (rows ?? []).filter(\.detected)
            if let note = model.connectedNote { ConnectedNote(text: note) }
            CodexTrustRow()
            if rows == nil, let err = agents.sourceError {
                Text("Kai can't list agents right now: \(err)").font(.system(size: 12)).foregroundStyle(Theme.amber)
            } else if rows == nil {
                ProgressView().controlSize(.small)
            } else if found.isEmpty {
                RecordList { Text("No supported agent found on this Mac.").foregroundStyle(Theme.muted).padding(28) }
            } else {
                RecordList {
                    ForEach(Array(found.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider() }
                        let (state, tone) = Self.state(a, agents)
                        VStack(alignment: .leading, spacing: 0) {
                            RecordRow(letter: String(LiveCoverage.title(a.name).prefix(2)),
                                      title: LiveCoverage.title(a.name), subtitle: state + " · " + ActivityFeed.coverage(a.name),
                                      tone: tone) { nav.showActivity(agent: a.name) }
                            if let ag = Agent(rawValue: a.name) {
                                HStack {
                                    Spacer()
                                    if a.hooks == "failing" {
                                        Button("Reconnect") { model.setAgent(ag, enabled: true) }
                                            .buttonStyle(LimeButtonStyle(subtle: true))
                                    }
                                    // 0.4.1: on by default; the switch is the only control.
                                    Toggle("On", isOn: Binding(get: { a.hooks != "missing" && a.hooks != "not found" },
                                                               set: { model.setAgent(ag, enabled: $0) }))
                                        .toggleStyle(KaiToggleStyle()).labelsHidden()
                                        .disabled(model.busy || model.status == nil)
                                        .help("On: Kai's hooks are in \(ag.title)'s settings. Off: Kai leaves it alone "
                                              + "and won't connect it again on its own.")
                                }
                                .padding(.horizontal, 16).padding(.bottom, 10)
                            }
                        }
                    }
                }
                Text("Connected and Not connected are about Kai's integration only. Working: a connected agent "
                     + "ran a command in the last 15 minutes.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }

    @MainActor
    static func state(_ a: AgentRow, _ agents: AgentsModel) -> (String, Color) {
        let title = LiveCoverage.title(a.name)
        let working = agents.workingNow.filter { $0.displayAgent == title }.count
        let running = agents.interactiveSessions.contains { $0.isActive && $0.displayAgent == title }
        if a.hooks == "installed" {
            return (working > 0 ? "Connected · \(working) working" : "Connected · no recent activity", Theme.muted)
        }
        if a.hooks == "untrusted" {
            return ("Connected · Codex hasn't run Kai's hook yet: not checked until you run /hooks in Codex", Theme.amber)
        }
        if a.hooks == "missing" && UserDefaults.standard.stringArray(forKey: AutoConnect.disabledKey)?.contains(a.name) == true {
            return ("Off · you turned it off", Theme.muted)
        }
        if running { return ("Not connected · running · activity unknown", Theme.amber) }
        return ("Not connected · activity unavailable", Theme.amber)
    }
}

// MARK: - Decisions

struct DecisionsPageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = MainNav.shared
    let workspace: String?

    /// Recorded stops in this workspace, one entry per stop, newest first.
    private var stops: [AuditEvent] {
        var seen = Set<String>()
        return model.events.filter { e in
            e.isBlock && !e.isNote && !e.isSilent && !e.isGrant
                && (e.isNetwork || ActivityFeed.inWorkspace(e.cwd, workspace))
                && seen.insert(e.decision_id ?? e.id).inserted
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var body: some View {
        PageColumn(title: "Decisions", subtitle: Text("Stops Kai recorded in ") + Text(Workspaces.name(workspace)).bold()) {
            if stops.isEmpty {
                RecordList {
                    VStack(spacing: 6) {
                        Text("No recorded stops.").foregroundStyle(Theme.muted)
                        Text("No record doesn't mean nothing risky happened.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(28)
                }
            } else {
                RecordList {
                    ForEach(Array(stops.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider() }
                        let item = ActivityFeed.stopItem(e, workspace: workspace)
                        RecordRow(letter: "!", title: item.title, subtitle: "\(item.agent) · \(item.detail)",
                                  meta: e.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "",
                                  tone: Theme.amber, askAbout: { nav.ask(about: item) }) { nav.openDecision = e }
                    }
                }
            }
        }
    }
}

/// One stop: the reason in one line, what a retry would get now (kai why),
/// technical details, and, for an eligible file read, a narrow allow after an
/// explicit confirmation.
struct DecisionDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var records = KaiRecords.shared
    @Environment(\.dismiss) private var dismiss
    let event: AuditEvent
    let workspace: String?
    @State private var why: WhyRecord?
    @State private var confirming = false
    @State private var showDetails = false
    @State private var result: String?

    private var item: ActivityItem { ActivityFeed.stopItem(event, workspace: workspace) }
    private var allow: NarrowAllow.Eligibility { NarrowAllow.eligibility(event) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.system(size: 20, weight: .semibold))
            Text(event.detail.sentenceEnded).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if let r = why?.retryLine {
                Text(r.sentenceEnded).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if event.isNetwork {
                DecisionSheet(event: event, grants: GrantManager.shared).environmentObject(model)
            }
            DisclosureGroup("Technical details", isExpanded: $showDetails) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    detail("Agent", event.agentName)
                    detail("Checked by", why?.component ?? (event.isNetwork ? "network wall" : "agent hook"))
                    detail("Rule", event.rule)
                    detail("Tool", event.tool ?? "—")
                    detail("Target", event.excerpt ?? "—")
                    detail("Session", why?.attribution ?? event.session ?? "—")
                    detail("Decision", event.decision_id ?? "—")
                    detail("Time", event.date?.formatted(date: .abbreviated, time: .standard) ?? event.ts)
                }
                .font(.system(size: 12)).padding(.top, 6)
            }
            if let result { Text(result).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            HStack {
                switch allow {
                case .eligible:
                    Button("Allow for this session…") { confirming = true }
                case .terminalOnly(let why):
                    Text("\(why) Run it in your own terminal.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                case .notApplicable:
                    EmptyView()
                }
                Spacer()
                Button("Ask about this") { dismiss(); nav.ask(about: item); nav.page = .ask }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(26)
        .frame(width: 560)
        .task { if let id = event.decision_id { why = await records.why(id) } }
        .sheet(isPresented: $confirming) {
            AllowConfirmSheet(event: event) { ok in
                confirming = false
                if ok { result = NarrowAllow.grant(event) }
            }
        }
    }

    @ViewBuilder private func detail(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }
}

/// The confirmation the user gives before any allow: one agent, one exact
/// file, reads only, five minutes.
struct AllowConfirmSheet: View {
    let event: AuditEvent
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow this one file for 5 minutes?").font(.system(size: 17, weight: .semibold))
            Text("\(event.agentName) may read \(NarrowAllow.path(event) ?? "this file") with its file tool for the "
                 + "next 5 minutes. Nothing else changes: other files, other agents, shell commands such as `cat`, "
                 + "and uploads stay checked.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Allow for 5 minutes") { done(true) }.buttonStyle(LimeButtonStyle())
            }
        }
        .padding(24).frame(width: 440)
    }
}

/// The only allow the app offers from a decision: one agent, one exact file,
/// one operation (read), 5 minutes, after the user confirms. Never a private
/// key, never Kai's own settings.
enum NarrowAllow {
    enum Eligibility: Equatable { case eligible, terminalOnly(String), notApplicable }

    static func path(_ e: AuditEvent) -> String? {
        guard var p = e.excerpt, !p.contains("REDACTED") else { return nil }
        if !p.hasPrefix("/") && !p.hasPrefix("~") {
            guard let c = e.cwd, !c.isEmpty else { return nil }
            p = (c as NSString).appendingPathComponent(p)
        }
        return (p as NSString).expandingTildeInPath
    }

    static func isPrivateKey(_ p: String) -> Bool {
        let l = p.lowercased()
        let name = (l as NSString).lastPathComponent
        return l.contains("/.ssh/") || l.contains("/.gnupg/") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519")
            || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_dsa")
            || [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks"].contains { name.hasSuffix($0) }
    }

    static func isKaiSettings(_ e: AuditEvent, _ p: String) -> Bool {
        e.isBuiltinRule || p.contains("/.kai/") || p.hasSuffix("/.kai") || p.contains("/Application Support/Kai/")
    }

    static func eligibility(_ e: AuditEvent) -> Eligibility {
        guard e.isBlock, !e.isNetwork, !e.isStorage, ["claude", "cursor"].contains(e.source),
              e.tool == "Read", let p = path(e) else { return .notApplicable }
        if isPrivateKey(p) { return .terminalOnly("Kai never allows private keys from the app.") }
        if isKaiSettings(e, p) { return .terminalOnly("Kai's own settings can't be allowed from the app.") }
        return .eligible
    }

    /// Adds the grant in-process (the app keeps the rules) and records it.
    static func grant(_ e: AuditEvent) -> String {
        guard eligibility(e) == .eligible, let p = path(e) else { return "This can't be allowed from the app." }
        let until = Int64(Date().timeIntervalSince1970) + 300
        var err = [CChar](repeating: 0, count: 300)
        let rc = kai_cli_grant_add(1, "read", e.source, p, nil, until, nil, &err, err.count)
        guard rc == 0 else { return "Kai couldn't save the allow: \(String(cString: err))" }
        let home = NSHomeDirectory()
        let shown = p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
        _ = kai_audit("kai", "allow-file", "note", "terminal_grant",
                      "Kai app: allowed \(e.source) to read \(shown) with its file tool for 5 minutes, confirmed by the user")
        return "Allowed for 5 minutes: \(e.agentName) may read this file with its file tool. Ask it to retry."
    }
}
