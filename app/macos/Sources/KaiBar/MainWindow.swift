// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: the Kai window. Sidebar: Now (home), Activity, Ask Kai, with Settings
// pinned at the bottom. Toolbar: the health pill (its count comes from the
// same NowSummary as the Now header), appearance and a menu. The Ask dock is
// at the bottom of every page (⌘K focuses it, ⌘J hides it). Every project is
// in scope; a project is a filter on Activity, and each Now card names its
// own.
import AppKit
import SwiftUI
import KaiCore

enum MainPage: String, CaseIterable, Identifiable {
    case now, activity, ask, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Now"
        case .activity: return "Activity"
        case .ask: return "Ask Kai"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .now: return "dot.radiowaves.left.and.right"
        case .activity: return "list.bullet.rectangle"
        case .ask: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

/// Where the window is and what it shows; the popover and kai:// links drive it.
@MainActor
final class MainNav: ObservableObject {
    static let shared = MainNav()
    @Published var page: MainPage = .now
    // Activity filters (0.5): kind, agent, session, project. nil = all.
    @Published var filter: TimelineFilter = .all
    @Published var agentFilter: String? = nil
    @Published var sessionFilter: String? = nil
    /// The project filter (a path). 0.4's toolbar workspace picker became this.
    @Published var projectFilter: String? = nil
    @Published var search = ""
    @Published var openEvent: TimelineEvent? = nil
    @Published var openItem: ActivityItem? = nil
    @Published var openDecision: AuditEvent? = nil
    @Published var chatHidden = false
    @Published var focusChat = 0
    @Published var askContext: ActivityItem? = nil
    /// Now → Ask about this: the session the dock asks about.
    @Published var askSession: SessionFocus? = nil

    func show(_ p: MainPage) { page = p }
    func showActivity(agent: String?) {
        agentFilter = agent; sessionFilter = nil; filter = .all; search = ""; page = .activity
    }
    func showActivity(session: String, agent: String) {
        // 0.5.1: Open → always lands on the All filter, never the last-used one.
        sessionFilter = session; agentFilter = agent; projectFilter = nil; filter = .all; search = ""; page = .activity
    }
    func showStops() { filter = .stops; sessionFilter = nil; page = .activity }
    func ask(about item: ActivityItem) {
        openItem = nil
        openEvent = nil
        askSession = nil
        askContext = item
        AskController.shared.startThread(title: item.title, quote: ([item.title, item.agent] + (item.detail.isEmpty ? [] : [item.detail]))
                                            .filter { !$0.isEmpty }.joined(separator: " · "), agent: item.agentKey)
        chatHidden = false
        focusChat += 1
    }
    func ask(aboutSession s: SessionFocus) {
        askContext = nil
        askSession = s
        AskController.shared.startThread(title: "About \(s.agentTitle) · \(s.project)",
                                         quote: ([s.agentTitle, s.project, s.tab, s.state].filter { !$0.isEmpty && $0 != "—" })
                                            .joined(separator: " · ") + (s.last.map { "\n" + $0 } ?? ""), agent: s.agent)
        chatHidden = false
        focusChat += 1
    }
    func go(_ r: KaiRoute) {
        switch r {
        case .now: page = .now
        case .activity(let stops): if stops { showStops() } else { page = .activity }
        case .ask: page = .ask
        case .settings(let p):
            UserDefaults.standard.set(p.rawValue, forKey: "settingsPage")
            page = .settings
        }
    }
}

/// What the Kai window reads beyond AppModel and AgentsModel: the recorder's
/// groups and sessions (all projects) and `kai why` per decision.
@MainActor
final class KaiRecords: ObservableObject {
    static let shared = KaiRecords()
    @Published private(set) var groups: ActivityGroups? = nil
    @Published private(set) var why: [String: WhyRecord] = [:]
    private var loading = false

    func refresh() async {
        #if DEBUG
        if ScreenshotFixture.active { return }
        #endif
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let r = await KaiCLI.run(["activity", "--json", "--since", "24h"])
        let g = r.ok ? ActivityGroups.parse(r.out) : nil
        if g != groups { groups = g }
    }

    func why(_ id: String) async -> WhyRecord? {
        if let w = why[id] { return w }
        let r = await KaiCLI.run(["why", id, "--json"])
        guard r.ok, let w = WhyRecord.parse(r.out) else { return nil }
        why[id] = w
        return w
    }
}

/// The projects Kai knows from sessions and records, most recently active first.
enum Workspaces {
    static func list(_ sessions: [SessionRow], records: [SessionActivity] = []) -> [(path: String, last: Int)] {
        var best: [String: Int] = [:]
        for s in sessions {
            if !s.project.isEmpty, s.project != "/" { best[s.project] = max(best[s.project] ?? 0, s.lastActiveUtc, s.startedUtc) }
            for w in s.workspaces ?? [] { best[w.path] = max(best[w.path] ?? 0, w.lastActiveUtc) }
        }
        for r in records where !r.workspace.isEmpty && r.workspace != "/" {
            best[r.workspace] = max(best[r.workspace] ?? 0, Int(r.last))
        }
        let home = NSHomeDirectory()
        return best.filter { $0.key != home }.map { ($0.key, $0.value) }.sorted { $0.last > $1.last }
    }
    static func name(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "All projects" }
}

/// Now's data, built once per render from the shared stores: the Now page,
/// the toolbar pill and the popover all read this, so their counts agree.
@MainActor
enum NowData {
    static func sections(_ model: AppModel) -> [NowSection] {
        NowBuilder.sections(sessions: AgentsModel.shared.sessions,
                            records: KaiRecords.shared.groups?.sessions ?? [], events: model.events)
    }
    static func summary(_ model: AppModel) -> NowSummary { NowSummary.of(sections(model)) }
}

/// The header: the most important problem wins. One agent that isn't
/// connected never reads as "all checks are off". Dot: teal when connected
/// and fine, amber when something needs the user, red when Kai is off, grey
/// only when no agent is connected.
struct HeaderState: Equatable {
    enum Tone { case ok, attention, off, none }
    var text: String
    var tone: Tone
    var detail: String? = nil
    /// 0.5.1: an agent's hooks failed their test: "Claude Code's hooks need repair", with Repair.
    var needsRepair = false

    @MainActor
    static func make(_ model: AppModel, _ agents: AgentsModel) -> HeaderState {
        make(model, agents, summary: NowData.summary(model))
    }

    @MainActor
    static func make(_ model: AppModel, _ agents: AgentsModel, summary: NowSummary) -> HeaderState {
        if model.cliPath == nil || Lifecycle.programMissing {
            return HeaderState(text: "Kai is off", tone: .off, detail: "Kai's program is missing. Reinstall the Kai package.")
        }
        guard let rows = model.displayAgents(agents) else {
            if agents.sourceError != nil && Date().timeIntervalSince(AppModel.launchedAt) >= 5 {
                return HeaderState(text: "Kai can't list agents right now", tone: .attention, detail: agents.sourceError)
            }
            return HeaderState(text: "Checking hooks…", tone: .none)   // only while the first check runs
        }
        let found = rows.filter(\.detected)
        if found.isEmpty { return HeaderState(text: "No supported agent found", tone: .none) }
        if !found.contains(where: { $0.hooks == "installed" || $0.hooks == "untrusted" }) {
            return HeaderState(text: "No agent connected", tone: .none, detail: "Turn an agent on in Settings → Agents.")
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
            return HeaderState(text: "\(StopWords.possessive(ActivityFeed.agentTitle(broken.name))) hooks need repair", tone: .attention,
                               detail: "Kai's hook didn't answer a test request.", needsRepair: true)
        }
        if found.contains(where: { $0.hooks == "untrusted" }) {
            return HeaderState(text: "Codex needs one step", tone: .attention, detail: AutoConnect.codexTrustLine)
        }
        if let missing = found.first(where: { $0.hooks != "installed" && !AppModel.userTurnedOff($0.name) }) {
            return HeaderState(text: "\(ActivityFeed.agentTitle(missing.name)) isn't connected", tone: .attention,
                               detail: "Kai doesn't check it until it's connected.")
        }
        return HeaderState(text: summary.working + summary.idle > 0 ? summary.text : "Connected", tone: .ok)
    }

    var color: Color {
        switch tone {
        case .ok: return Theme.teal
        case .attention: return Theme.amber
        case .off: return Theme.coral
        case .none: return Theme.muted
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

    private var header: HeaderState { HeaderState.make(model, agents) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if header.tone == .attention || header.tone == .off { banner }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !nav.chatHidden {
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
        .sheet(item: $nav.openEvent) { e in
            TimelineEventSheet(event: e).environmentObject(model)
        }
        .sheet(item: $nav.openDecision) { e in
            DecisionDetailSheet(event: e, workspace: nil).environmentObject(model)
        }
        .background(shortcuts)
        .task {
            // Every 3 s while the window is visible, every 15 s otherwise.
            await reload()
            while !Task.isCancelled {
                let visible = NSApp.isActive && NSApp.windows.contains {
                    $0.isVisible && $0.occlusionState.contains(.visible) && $0.title == "Kai"
                }
                try? await Task.sleep(nanoseconds: (visible ? 3 : 15) * 1_000_000_000)
                await reload()
            }
        }
    }

    private func reload() async {
        await model.refresh()
        await agents.refresh()
        await records.refresh()
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
            ForEach([MainPage.now, .activity, .ask]) { p in
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
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.raised.opacity(0.6), in: Capsule())
            .help(header.detail ?? header.text)
            .accessibilityElement(children: .combine)
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
            if header.text.hasSuffix("isn't connected") || header.text.hasPrefix("Codex") {
                Button("Settings → Agents") { nav.go(.settings(.agents)) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(header.color.opacity(0.10))
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .now: NowPageView()
        case .activity: ActivityTimelineView()
        case .ask: AskKaiPage(context: { makeContext() })
        case .settings: SettingsView()
        }
    }

    // MARK: Ask Kai context: structured records only

    func makeContext() -> AskContext {
        MainWindowView.context(model: model, wall: wall, agents: agents, records: records, nav: nav)
    }

    static func context(model: AppModel, wall: NetworkWall, agents: AgentsModel, records: KaiRecords,
                        nav: MainNav) -> AskContext {
        let items = ActivityFeed.build(groups: records.groups, events: model.events, workspace: nil,
                                       internetWatching: wall.isOn)
        let stops = ActivityFeed.stops(model.events, workspace: nil)
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
        return AskContext(workspace: nil, recording: model.recordingActivity || (records.groups?.recording ?? false),
                          internetWatching: wall.isOn, items: items, stops: stops, agents: askAgents,
                          why: records.why, focus: nav.askContext,
                          version: model.status?.version ?? "", commit: model.status?.commit ?? "",
                          internet: internet,
                          recordingFirst: first.flatMap { Calendar.current.isDateInToday($0) ? $0 : nil },
                          policyProblem: model.status.flatMap { $0.policy.ok ? nil : $0.policy.error },
                          paused: GrantManager.shared.pauseState(nil) != Int32(KAI_PAUSE_NONE),
                          session: nav.askSession)
    }
}

extension AppModel {
    var recordingActivity: Bool { policy?.switches["record_activity"] == "on" }
    /// The user turned this agent off in Kai (it won't be connected again on its own).
    static func userTurnedOff(_ agent: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: AutoConnect.disabledKey)?.contains(agent) == true
    }
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
                Button("Ask about this →") { nav.ask(about: item); nav.page = .ask }
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
    /// The `kai why` record: fetched when the sheet opens, else the cached one.
    private var whyRec: WhyRecord? { why ?? event.decision_id.flatMap { records.why[$0] } }
    @State private var notRight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 0.5.1: what was stopped, with Kai as the subject.
            Text(StopWords.line(event)).font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            // Why.
            Text(event.detail.sentenceEnded).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if let r = whyRec?.retryLine {
                Text(r.sentenceEnded).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            if let rec = whyRec?.recovery, !rec.isEmpty {
                Text("What you can do: \(rec)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if event.isNetwork {
                DecisionSheet(event: event, grants: GrantManager.shared).environmentObject(model)
            }
            DisclosureGroup("Technical details", isExpanded: $showDetails) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    detail("Agent", event.agentName)
                    detail("Checked by", whyRec?.component ?? (event.isNetwork ? "network wall" : "agent hook"))
                    detail("Rule", event.rule)
                    detail("Tool", event.tool ?? "—")
                    // A command shows only its program name, never the command line.
                    detail("Target", event.excerpt.map { event.actionLabel == "Command" ? ActivityFeed.program($0) : $0 } ?? "—")
                    detail("Session", whyRec?.attribution ?? event.session ?? "—")
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
                // "Not right": this stop was a false positive (recorded on this Mac).
                if let id = event.decision_id, !id.isEmpty {
                    if let n = notRight {
                        Text(n).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    } else {
                        Button("Not right") {
                            Task {
                                let r = await KaiCLI.run(["not-right", id])
                                notRight = r.ok ? "Marked. Thanks." : "Couldn't mark it: \(r.message)"
                            }
                        }
                        .help("Tell Kai this stop was wrong. It's recorded on this Mac as a false positive.")
                    }
                }
                Spacer()
                Button("Ask about this →") { dismiss(); nav.ask(about: item); nav.page = .ask }
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

#if DEBUG
extension KaiRecords {
    func loadFixture(groups: ActivityGroups?, why: [String: WhyRecord]) {
        self.groups = groups
        self.why = why
    }
}
#endif
