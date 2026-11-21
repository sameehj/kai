// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import SwiftUI
import KaiCore

/// The panel that drops down from the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPage") private var settingsPage = SettingsPage.general.rawValue
    @State private var dismissedBlock: String?
    @State private var showPermissions = false
    @State private var openDecision: String?
    @ObservedObject private var grantManager = GrantManager.shared
    @ObservedObject private var agents = AgentsModel.shared

    private var alert: AuditEvent? {
        guard let b = model.freshBlock, b.id != dismissedBlock else { return nil }
        return b
    }

    // 0.3 order, top to bottom: header from measured state · Needs you (only
    // when something waits) · one row per agent · the coverage line (opens
    // the coverage screen) · Recent stops · footer (Pause 15 min · Settings).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            alerts
            if !grantManager.pendingPolicy.isEmpty || !grantManager.pending.isEmpty { needsYou }
            migratedConfirm
            pausedBanner
            if DevFlags.perSessionPause { pauseBanner }
            agentRows
            latestStop
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.ink)
        .foregroundStyle(Theme.text)
        .task { await model.refresh(); wall.refresh(); await agents.refresh() }
    }

    /// Things that change what the header means: notifications off, an
    /// agent Kai's broken hooks can't check, an error from the last action.
    @ViewBuilder private var alerts: some View {
        if model.notificationsOff {   // Nov 2: a banner, not a footnote
            HStack(alignment: .top, spacing: 8) {
                Text("Notifications are off, so you won't see when Kai stops an agent.")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Turn on") { Notifier.openSettings() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime)
                    .help("Opens System Settings → Notifications → Kai.")
            }
            .padding(10)
            .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        // STEP 2c: an agent Kai's own broken hooks can't check
        ForEach(LiveCoverage.blocked(agents: agents.loaded ? agents.agents : []), id: \.agent) { b in
            BlockedAgentBanner(banner: b) { Task { await AgentsModel.shared.refresh() } }
        }
        if let msg = model.errorMessage { ErrorBanner(message: msg) { model.errorMessage = nil } }
    }

    /// One row per agent found on this Mac: its check state in words and how
    /// many of its sessions are working. A row opens Agent Control.
    @ViewBuilder private var agentRows: some View {
        if let err = agents.sourceError {
            // Never a false "no agents": the list couldn't be read.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Kai can't list agents right now ·").font(.system(size: 12)).foregroundStyle(Theme.amber)
                Button("Details") { openDecision = openDecision == "sessions-error" ? nil : "sessions-error" }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                    .popover(isPresented: Binding(get: { openDecision == "sessions-error" },
                                                  set: { if !$0 { openDecision = nil } }), arrowEdge: .leading) {
                        Text(err).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 340)
                    }
            }
        } else if !agents.loaded {
            Text("Looking for agents…").font(.system(size: 12)).foregroundStyle(Theme.soft)
        } else {
            let found = agents.agents.filter(\.detected)
            VStack(alignment: .leading, spacing: 4) {
                if found.isEmpty {
                    Text("No supported agent found on this Mac.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(found) { a in
                    let (word, tone) = Self.agentState(a)
                    let working = agents.workingNow.filter { $0.displayAgent == LiveCoverage.title(a.name) }.count
                    Button { MainNav.shared.showActivity(agent: a.name); openMain() } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.coverage(tone)).frame(width: 7, height: 7)
                            Text(LiveCoverage.title(a.name)).font(.system(size: 13, weight: .medium))
                            Text(word).font(.system(size: 12)).foregroundStyle(tone == .problem ? Theme.coral : Theme.muted)
                            Spacer()
                            if working > 0 {
                                Text("\(working) working").font(.system(size: 11)).foregroundStyle(Theme.soft)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func agentState(_ a: AgentRow) -> (String, LiveCoverage.Tone) {
        switch a.hooks {
        case "installed": return ("Checking", .checking)
        case "failing": return ("Checks off: broken", .problem)
        default: return ("Not checking", .off)
        }
    }

    /// One line; the details are on the coverage screen.
    private var coverageLine: some View {
        Button { openDecision = openDecision == "coverage" ? nil : "coverage" } label: {
            HStack(spacing: 6) {
                Text("Coverage: what Kai checks, and what it can't see").font(.system(size: 12)).foregroundStyle(Theme.soft)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { openDecision == "coverage" },
                                      set: { if !$0 { openDecision = nil } }), arrowEdge: .leading) {
            CoverageScreen()
        }
    }

    // Migration: one line; the details (Keep, Remove) are on the
    // agent's page behind Review.
    @AppStorage("agentControlOpen") private var agentControlOpen = ""
    @ViewBuilder private var migratedConfirm: some View {
        let ms = grantManager.migratedRules
        if let first = ms.first {
            let name = ms.count == 1 ? HostCatalog.shortName(first.dest) : "\(ms.count) sites"
            let days = max(1, Int((Double(first.expires) - Date().timeIntervalSince1970) / 86400.0 + 0.5))
            Button {
                agentControlOpen = "agent:" + first.agent
                MainNav.shared.page = .agents; openMain()
            } label: {
                Text("Kai tidied up an old setting: \(name) \(ms.count == 1 ? "is" : "are") allowed for \(first.agentTitle) "
                     + "for \(days) day\(days == 1 ? "" : "s"). Review ›")
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain)
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !grantManager.pendingPolicy.isEmpty || !grantManager.pending.isEmpty {
                CapsLabel("Needs you")
                ForEach(grantManager.pendingPolicyGroups, id: \.first!.id) { PendingPolicyCard(changes: $0, manager: grantManager) }
                // Repeats within a session collapse into one card with a count.
                ForEach(grantManager.pendingGroups) {
                    ApprovalCard(req: $0.rep, count: $0.count, manager: grantManager)
                }
                if grantManager.pendingGroups.count > 1 {
                    Button("Keep all blocked") { grantManager.dismissAllPending() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            // B1: active only here (history lives in Agent Control); every row
            // names agent, resource, scope and time left.
            let active = grantManager.grantGroups.filter { !$0.isExpired }
            let n = active.reduce(0) { $0 + $1.count }
            if !active.isEmpty {
                Button { withAnimation { showPermissions.toggle() } } label: {
                    HStack {
                        Text("\(n) permission\(n == 1 ? "" : "s")").font(.system(size: 12))
                        Image(systemName: showPermissions ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        Spacer()
                    }.foregroundStyle(Theme.soft).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !active.isEmpty && showPermissions {
                ForEach(active) { g in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(g.agent) · \(g.opLabel) \(g.resourceLabel) · \(g.scopeLabel)"
                                 + (g.count > 1 ? " ×\(g.count)" : "")).font(.system(size: 12))
                                .lineLimit(1).truncationMode(.middle)
                                .help(g.resource)
                            Text(g.status).font(.system(size: 11)).foregroundStyle(Theme.lime)
                        }
                        Spacer()
                        Button(g.count > 1 ? "Revoke all" : "Revoke") { grantManager.revokeGroup(g) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.coral)
                    }
                }
            }
        }
    }

    // Phase A item 5 / B3: one guaranteed way out. Pause (footer) stops both
    // walls for 15 minutes and resumes by itself; while paused, a banner says
    // what that means, with the end time, Resume and +15 min.
    @ViewBuilder private var pausedBanner: some View {
        let st = grantManager.pauseState(nil)
        if st != Int32(KAI_PAUSE_NONE) {
            PauseControl(state: st, until: grantManager.pauseEnds(nil),
                         title: "Kai is paused until \(grantManager.pauseEnds(nil).map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon")",
                         note: PauseText.global,
                         pause: {}, resume: { grantManager.pauseAll(minutes: 0) },
                         extend: { grantManager.extendPause(nil) })
        }
    }

    // Item 1: a persistent banner while any session is paused, with Resume.
    // (Pauses auto-resume and are capped at 1 day in the engine.)
    @ViewBuilder private var pauseBanner: some View {
        let paused = agents.pausedSessions
        ForEach(paused) { s in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.displayAgent) · \(s.name)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                PauseControl(state: grantManager.pauseState(s.id), until: grantManager.pauseEnds(s.id),
                             pause: { grantManager.pauseSession(s.id, minutes: 15) },
                             resume: { grantManager.pauseSession(s.id, minutes: 0) },
                             extend: { grantManager.extendPause(s.id) })
            }
        }
    }

    private func openAgentControl() { MainNav.shared.page = .agents; openMain() }

    /// 0.3: the header's words and colour, from measured state (LiveCoverage.headline).
    /// Red only when Kai itself is broken; a routine stop is never red.
    private var status: LiveCoverage.Headline { model.headline(agents) }

    private var glow: Color {
        if model.health == .problem { return Theme.coral }
        return Theme.coverage(status.tone)
    }

    private var background: some View {
        ZStack {
            Theme.ink
            RadialGradient(colors: [glow.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 320)
        }
        .animation(.easeInOut(duration: 0.6), value: glow)
    }

    // 0.3: the header says what Kai is doing, in words next to the colour:
    // Checking · Partly checking · Not checking, or, when Kai is broken,
    // "Kai's checks are off; its settings aren't protected" with Repair.
    private var header: some View {
        let h = HeaderState.make(model, agents)
        let n = agents.workingNow.count
        return HStack(alignment: .top, spacing: 10) {
            Image("KaiLogo").resizable().frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kai · \(n) working session\(n == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(h.color).frame(width: 7, height: 7)
                    Text(h.text).font(.system(size: 11)).foregroundStyle(h.tone == .ok ? Theme.muted : h.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.status == .broken && LiveCoverage.blocked(agents: agents.loaded ? agents.agents : []).isEmpty {
                    RepairButton { Task { await model.refresh(); await agents.refresh() } }
                }
            }
            .layoutPriority(1)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            if !KaiInstance.isRelease { DevBadge().fixedSize() }
        }
    }

    /// The latest stop, one line; it opens its decision in the Kai window.
    @ViewBuilder private var latestStop: some View {
        if let e = ActivityFeed.stops(model.events, workspace: nil).first {
            Button {
                MainNav.shared.page = .decisions
                MainNav.shared.openDecision = e
                openMain()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised").font(.system(size: 11)).foregroundStyle(Theme.amber)
                    Text("Latest stop: \(e.agentName) · \(ActivityFeed.stopItem(e, workspace: nil).detail)")
                        .font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                    Spacer()
                    if let d = e.date { Text(ago(d)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var recent: some View {
        if !recentItems.isEmpty || alert != nil || model.stoppedTodayCount > 0 { recentList }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CapsLabel("Recent stops")
                Spacer()
                Button("See all") { MainNav.shared.page = .decisions; openMain() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
            }
            if let b = alert {
                BlockNotice(event: b,
                            dismiss: { withAnimation { dismissedBlock = b.id } },
                            details: { MainNav.shared.page = .decisions; openMain() })
            }
            // Step 6: "N actions stopped today" opens the list (reason, command, choices).
            if model.stoppedTodayCount > 0 {
                HStack(spacing: 4) {
                    Button { openDecision = openDecision == "stopped" ? nil : "stopped" } label: {
                        Text(model.valueLine + " ›").font(.system(size: 12)).foregroundStyle(Theme.soft)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { openDecision == "stopped" },
                                                  set: { if !$0 { openDecision = nil } }), arrowEdge: .leading) {
                        StoppedTodayList(grants: grantManager, open: { MainNav.shared.page = .decisions; openMain() }).environmentObject(model)
                    }
                    InfoButton(text: InfoText.actionsStopped)
                }
            }
            // Spec §5.1: every row opens its decision sheet.
            ForEach(recentItems) { g in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { openDecision = openDecision == g.event.id ? nil : g.event.id } label: {
                        EventLine(event: g.event, count: g.count, plain: true).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    CopyButton(text: CardText.brief(g.event, sessionName: AgentsModel.shared.sessions
                        .first { $0.id == g.event.session }?.name))
                    // dogfood: a kept-blocked host is one click from asking again
                    if g.event.isKeptBlocked, let r = grantManager.keptBlockedRule(g.event) {
                        Button("Unblock") { grantManager.removeRule(r) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                            .help("Kai asks about \(r.dest) again next time.")
                    }
                }
                .popover(isPresented: Binding(get: { openDecision == g.event.id },
                                              set: { if !$0 { openDecision = nil } }), arrowEdge: .leading) {
                    DecisionSheet(event: g.event, count: g.count, grants: grantManager)
                        .environmentObject(model)
                        .padding(14).frame(width: 340)
                }
            }
        }
    }

    /// B3: Recent shows only meaningful events from the last hour.
    private var recentItems: [EventGroup] {
        let hourAgo = Date().addingTimeInterval(-3600)
        return Array(model.importantEventGroups.filter { ($0.event.date ?? .distantPast) > hourAgo }.prefix(3))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Ask Kai…") {
                MainNav.shared.page = .ask
                MainNav.shared.chatHidden = false
                MainNav.shared.focusChat += 1
                openMain()
            }
            .foregroundStyle(Theme.teal)
            if grantManager.pauseState(nil) == Int32(KAI_PAUSE_NONE) {
                Menu("Pause…") {
                    Button("Pause checks for 15 minutes") { grantManager.pauseAll(minutes: 15) }
                    Button("Pause checks for 1 hour") { grantManager.pauseAll(minutes: 60) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Kai's checks resume by themselves.")
            }
            Button("Settings") { open(.general) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.top, 2)
    }

    private func openMain() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(_ page: SettingsPage) {
        settingsPage = page.rawValue
        MainNav.shared.page = .settings
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Phase A item 3: a hook block, as a card with a next step, never a dead
/// end. (Wall blocks stage their own decision card in Needs you.) The rule and
/// excerpt live behind "Why?"; "Open Activity" is where "Not a threat" lives.
/// Step 6: what "N actions stopped today" opens. Each stop with its reason,
/// the command that triggered it, and the choices Kai has for it (Allow for
/// this task / Keep blocked for a connection; a tool call's own way out).
struct StoppedTodayList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var grants: GrantManager
    let open: () -> Void

    var body: some View {
        let groups = model.stoppedTodayGroups
        let listed = groups.reduce(0) { $0 + $1.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.valueLine).font(.system(size: 13, weight: .semibold))
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        DecisionSheet(event: g.event, count: g.count, grants: grants).environmentObject(model)
                        if !g.event.isNetwork && !g.event.isStorage && !g.event.detail.isEmpty {
                            Text(g.event.detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Divider()
                }
                if listed < model.stoppedTodayCount {
                    Button("\(model.stoppedTodayCount - listed) more in Activity ›", action: open)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                }
            }
            .padding(14)
        }
        .frame(width: 360).frame(maxHeight: 480)
    }
}

struct BlockNotice: View {
    let event: AuditEvent
    let dismiss: () -> Void
    let details: () -> Void
    @State private var showWhy = false

    var body: some View {
        Card(stroke: Color(hex: 0x27354A)) {   // a routine stop: neutral blue, never red
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "hand.raised").foregroundStyle(Theme.blue)
                    Text("\(event.agentName) was stopped").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let d = event.date { Text(ago(d)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    // The same brief as Activity's copy icon.
                    CopyButton(text: CardText.brief(event, sessionName: AgentsModel.shared.sessions
                        .first { $0.id == event.session }?.name))
                }
                Text((event.isPrompt ? "The prompt wasn't sent" : "The action didn't run")
                     + (event.detail.isEmpty ? "." : ": " + event.detail.sentenceEnded))
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
                if showWhy {
                    VStack(alignment: .leading, spacing: 4) {
                        if let x = event.excerpt {
                            Text(x).font(Theme.mono).foregroundStyle(Theme.soft).lineLimit(4)
                        }
                        if !event.rule.isEmpty {
                            Text("Rule: \(event.rule)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 8) {
                    Button("Dismiss", action: dismiss).buttonStyle(WhiteButtonStyle())
                    Button(event.canExemptCommand ? "Not a threat?" : "Open Activity", action: details)
                        .buttonStyle(GhostButtonStyle())
                    Spacer()
                    Button(showWhy ? "Hide" : "Why?") { withAnimation { showWhy.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

// MARK: - Pieces

struct AgentBadge: View {
    let agent: Agent
    private var style: (String, Color, Color) {
        switch agent.rawValue {
        case "claude": return ("C", Color(hex: 0x2B2420), Color(hex: 0xF0A27A))
        case "cursor": return ("Cu", Theme.raised, .white)
        case "codex": return ("Cx", Color(hex: 0x1E2A26), Color(hex: 0x7FE0B8))
        default: return (String(agent.title.prefix(1)), Theme.raised, .white)
        }
    }
    var body: some View {
        Text(style.0).font(Theme.display(14)).foregroundStyle(style.2)
            .frame(width: 32, height: 32)
            .background(style.1, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct AgentCard: View {
    @EnvironmentObject var model: AppModel
    let agent: Agent

    private func subtitle(_ info: KaiStatus.Agent) -> String {
        if info.broken { return "Not working: " + (info.problem ?? "check failed") }
        if info.installed { return "Agent checks on" }
        return info.detected ? "Agent checks off" : "Not found on this Mac"
    }

    var body: some View {
        let info = model.agentInfo(agent)
        Card(padding: 10) {
            HStack(spacing: 12) {
                AgentBadge(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle(info))
                        .font(.system(size: 12))
                        .foregroundStyle(info.broken || (!info.installed && info.detected) ? Theme.amber : Theme.muted)
                        .lineLimit(2)
                        .help(info.problem ?? "")
                }
                Spacer()
                Toggle(agent.title, isOn: Binding(get: { info.installed },
                                                  set: { model.setAgent(agent, enabled: $0) }))
                    .toggleStyle(KaiToggleStyle()).labelsHidden()
                    .disabled(model.busy || model.status == nil)
            }
        }
    }
}

/// One line in the menu's recent list.
/// Item 2: one compact row per running session in the popover's Active now.
struct PopoverSessionRow: View {
    let session: SessionRow
    var grants: Int = 0
    /// Step 6: the session's unique name (topic or project, plus the tab);
    /// session id, host app and tty are on its details page.
    private var title: String { session.name.isEmpty ? session.projectBase : session.name }
    private var secondLine: String {
        if session.workspaces != nil || session.topicLine.isEmpty { return session.activeLabel }
        return [session.projectBase, session.activeLabel]
            .filter { !$0.isEmpty && $0 != "—" && !title.hasPrefix($0) }.joined(separator: " · ")
    }
    private var badge: Color {
        session.checksOff ? Theme.amber : Theme.lime
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(badge).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if session.checksOff {
                        Text(session.enforcementShort).font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }
                    if grants > 0 {
                        Text("\(grants) permission\(grants == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(Theme.lime)
                    }
                }
                Text(secondLine).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EventLine: View {
    let event: AuditEvent
    var count: Int = 1
    var plain = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Theme.tone(event.tone)).frame(width: 8, height: 8)
            Text((plain ? event.plainSentence : event.summary) + (count > 1 ? "  ×\(count)" : ""))
                .lineLimit(nil)
                .font(.system(size: 13)).foregroundStyle(Theme.soft)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let d = event.date { Text(ago(d)).font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
    }
}

struct DotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

struct WhiteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(Theme.onTeal)
            .background(Theme.teal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.coral)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Theme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "now", "5m", "2h", "3d".
func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// Pause as a visible state, the same everywhere (popover, rows, session
/// header): "Pause 15 min" when active; "Pausing…" until the wall confirms;
/// "Paused · resumes HH:MM" with Resume and "+15 min" when it holds.
struct PauseControl: View {
    let state: Int32
    let until: Date?
    var pauseLabel = "Pause 15 min"
    var title: String? = nil
    var note = "Kai still stops agents changing its own settings."
    let pause: () -> Void
    let resume: () -> Void
    let extend: () -> Void

    var body: some View {
        switch Int(state) {
        case KAI_PAUSE_ACTIVE:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(Theme.amber)
                    Text(title ?? "Paused · resumes \(until.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon")")
                        .font(.system(size: 12, weight: title == nil ? .regular : .semibold))
                    Spacer()
                    Button("+15 min", action: extend)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Resume", action: resume)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                }
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        case KAI_PAUSE_PENDING:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Pausing…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel", action: resume)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        default:
            Button(action: pause) {
                Label(pauseLabel, systemImage: "pause.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            .help("Lets this through for 15 minutes, logged, then resumes by itself. Kai still stops agents changing its own settings.")
        }
    }
}

/// A copy that isn't /Applications/Kai.app with the release signature: it
/// never hosts the control service, and says so.
struct DevBadge: View {
    var body: some View {
        Text("DEV").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onTeal)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.amber, in: Capsule())
            .help("A development copy: it doesn't run Kai's control service. The installed Kai in /Applications does.")
    }
}

/// B3: per-session pause is out of the release contract until it is verified
/// end to end on the real extensions. Development copies only (never the
/// release /Applications/Kai.app, whatever its defaults say), and only when a
/// developer turns it on:
///   defaults write io.github.sameehj.kai.dev devPerSessionPause -bool YES
enum DevFlags {
    static var perSessionPause: Bool { !KaiInstance.isRelease && UserDefaults.standard.bool(forKey: "devPerSessionPause") }
    /// Nov 1 corrective change: Protect for the Internet wall waits for Guard.
    /// Release builds never offer it (libkai keeps them in Watch); a developer
    /// build shows it only with `defaults write io.github.sameehj.kai.dev devInternetProtect -bool YES`.
    static var internetProtect: Bool {
        kai_internet_protect_available() == 1 && UserDefaults.standard.bool(forKey: "devInternetProtect")
    }
}

enum PauseText {
    /// What a global pause means, exactly: the hooks and Files let soft blocks
    /// through and log them; the Internet wall lets everything through
    /// unrecorded; Kai's own files stay blocked.
    static let global = "Agents aren't being checked and nothing is stopped, except agents changing Kai's own "
        + "settings. Internet activity isn't recorded."
}

enum ProtectionText {
    /// Step 6: this release ships the Internet wall only.
    static let filesNotIncluded = "Files: not included in this release"
    /// "Files ✓", "Files: watching", "Files: off", "Files: not running".
    static func mark(_ name: String, level: Int32) -> String {
        switch level {
        case 2: return "\(name) ✓"
        case 1: return "\(name): watching"
        case 0: return "\(name): off"
        default: return "\(name): not running"
        }
    }
}

/// Step 5: one colour per event tone, everywhere an event is shown.
extension Theme {
    static func tone(_ t: EventTone) -> Color {
        switch t {
        case .stopped: return blue   // a routine stop is information, not an alarm
        case .allowed, .cleaned: return lime
        case .neutral: return muted
        case .warning: return amber
        }
    }
}

/// Step 6: what Kai covers right now, from live checks only (LiveCoverage):
/// the agents' measured hook state and the Internet wall's verified heartbeat.
struct LiveCoverageList: View {
    @ObservedObject private var agents = AgentsModel.shared
    var compact = false
    var body: some View {
        // the heartbeat level, read live; -1 when the extension can't be confirmed
        let level = Int(kai_wall_observed_level("network"))
        let known = agents.loaded && agents.sourceError == nil
        let rows = LiveCoverage.rows(agents: known ? agents.agents : [],
                                     internetLevel: level, protectAvailable: kai_internet_protect_available() == 1)
        let others = known ? LiveCoverage.others(agents: agents.agents) : []
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            CapsLabel("Coverage now")
            ForEach(rows, id: \.label) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.coverage(r.tone)).frame(width: 6, height: 6)
                    Text(r.label).font(.system(size: compact ? 12 : 13)).foregroundStyle(Theme.soft).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(r.state).font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(r.tone == .problem ? Theme.coral : Theme.muted).lineLimit(1)
                    InfoButton(text: r.info)
                }
            }
            // Nov 2: agents Kai supports that aren't on this Mac: Settings only, collapsed
            if !compact && !others.isEmpty {
                DisclosureGroup("Other supported agents (\(others.count))") {
                    Text(others.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }.font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// STEP 2c / C1: an agent whose Kai hooks can't run (it keeps working unchecked), at the top of the popover.
/// Repair rewrites the hooks to the installed Kai (kai doctor --fix); Turn off
/// removes Kai's hooks for that agent. Both run the installed CLI: no Terminal.
struct BlockedAgentBanner: View {
    let banner: LiveCoverage.Banner
    var done: () -> Void
    @State private var busy = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.coral)
            Text(result ?? banner.detail).font(.system(size: 11)).foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Repair") { repair() }.buttonStyle(.plain).foregroundStyle(Theme.lime)
                Button(banner.actions.last ?? "Turn off checks") { run(["uninstall", banner.agentKey]) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
                if busy { ProgressView().controlSize(.small) }
            }.font(.system(size: 12, weight: .medium)).disabled(busy)
        }
        .padding(10)
        .background(Theme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
    private func repair() {
        busy = true
        Task {
            let lines = await Lifecycle.repair()
            busy = false
            result = lines.joined(separator: " ")
            done()
        }
    }
    private func run(_ args: [String]) {
        busy = true
        Task {
            let r = await KaiCLI.run(args)
            await MainActor.run {
                busy = false
                result = r.ok ? (args.first == "uninstall" ? "Kai's checks are off for \(banner.agent)." : "Repaired.")
                               : "Couldn't do it: \(r.message)"
                done()
            }
        }
    }
}

/// 0.3 / §2.6: Repair when Kai itself is broken: puts a missing program back
/// from Kai.app's copy (one admin prompt), then repairs the hooks.
struct RepairButton: View {
    var done: () -> Void
    @State private var busy = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button("Repair") {
                    busy = true
                    Task {
                        let lines = await Lifecycle.repair()
                        busy = false
                        result = lines.joined(separator: " ")
                        done()
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime)
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let r = result {
                Text(r).font(.system(size: 11)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

extension Theme {
    /// Nov 2: green checking, neutral watching, grey off or not included, red a problem.
    static func coverage(_ t: LiveCoverage.Tone) -> Color {
        switch t {
        case .checking: return lime
        case .watching: return soft
        case .partial: return amber
        case .off, .notIncluded: return muted
        case .problem: return coral
        }
    }
}

/// Nov 2: the copy icon on every card. Visible on hover (and always to
/// VoiceOver, as "Copy details"); a click copies a plain-text brief and shows
/// a checkmark for 1.5 s. The brief never holds secret values or file contents.
struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var hover = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11)).foregroundStyle(copied ? Theme.lime : Theme.muted)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hover || copied ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(copied ? "Copied" : "Copy details")
        .accessibilityLabel("Copy details")
    }
}
