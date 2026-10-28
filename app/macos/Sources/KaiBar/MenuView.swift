// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import SwiftUI
import KaiCore

/// The panel that drops down from the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPage") private var settingsPage = SettingsPage.agentControl.rawValue
    @State private var dismissedBlock: String?
    @StateObject private var grantManager = GrantManager()
    @StateObject private var agents = AgentsModel()

    private var alert: AuditEvent? {
        guard let b = model.freshBlock, b.id != dismissedBlock else { return nil }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let msg = model.errorMessage { ErrorBanner(message: msg) { model.errorMessage = nil } }
            if let b = alert {
                BlockNotice(event: b,
                            dismiss: { withAnimation { dismissedBlock = b.id } },
                            details: { open(.activity) })
            }
            statusLine
            globalPause
            pauseBanner
            protection
            needsYou
            activeNow
            permissions
            recent
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(background)
        // The menu-bar panel follows the system appearance and ignores
        // preferredColorScheme: force dark and a white default text color.
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
        .task { await model.refresh(); wall.refresh(); await agents.refresh() }
    }

    // Item 2: a short status headline + a full second line (no truncation),
    // from observed enforcement only — replaces the big shield and the weekly
    // counters (those stay in the window).
    private var statusLine: some View {
        let running = agents.workingNow.count   // the one definition: working now
        let needs = grantManager.pending.count + grantManager.pendingPolicy.count
        let activeGrants = grantManager.grants.count
        let blockedToday = model.events.filter {
            $0.isBlock && ($0.date.map { Calendar.current.isDateInToday($0) } ?? false)
        }.count
        return VStack(alignment: .leading, spacing: 3) {
            // headline from the shared measured status (observed enforcement)
            Text(model.statusSentence(storageOn: storage.isOn, networkOn: wall.isOn, agents: running))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.health == .problem ? Theme.coral : glow)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.internetUnverifiedNote(networkOn: wall.isOn) {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(running)").font(Theme.display(34)).foregroundStyle(glow)
                Text("agent\(running == 1 ? "" : "s") working now")
                    .font(.system(size: 13)).foregroundStyle(Theme.soft)
            }
            HStack(spacing: 6) {
                Text("\(needs) needs you").foregroundStyle(needs > 0 ? Theme.amber : Theme.muted)
                Text("·").foregroundStyle(Theme.muted)
                Text("\(activeGrants) permission\(activeGrants == 1 ? "" : "s")").foregroundStyle(Theme.muted)
                Text("·").foregroundStyle(Theme.muted)
                Text("\(blockedToday) blocked today").foregroundStyle(Theme.muted)
            }.font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !grantManager.pendingPolicy.isEmpty || !grantManager.pending.isEmpty {
                CapsLabel("Needs you")
                ForEach(grantManager.pendingPolicy) { PendingPolicyCard(change: $0, manager: grantManager) }
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

    // Working now — sessions with a command or hook in the last 15 minutes
    // (opens Agent Control); idle ones are counted, not listed.
    private var activeNow: some View {
        let running = agents.workingNow
        let idleCount = agents.idle.count
        let groups = Dictionary(grouping: running, by: { $0.displayAgent })
        return VStack(alignment: .leading, spacing: 6) {
            if !running.isEmpty || idleCount > 0 {
                HStack {
                    CapsLabel("Working now")
                    Spacer()
                    Button("Open Agent Control") { openAgentControl() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                }
                ForEach(groups.keys.sorted(), id: \.self) { ag in
                    let rows = groups[ag] ?? []
                    Text("\(ag) · \(rows.count)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    ForEach(rows.prefix(4)) { s in
                        let gc = grantManager.grants.filter { $0.session_id == s.id }.count
                        Button { openAgentControl() } label: { PopoverSessionRow(session: s, grants: gc) }
                            .buttonStyle(.plain)
                        if grantManager.pauseState(s.id) == Int32(KAI_PAUSE_NONE) {
                            PauseControl(state: Int32(KAI_PAUSE_NONE), until: nil,
                                         pause: { grantManager.pauseSession(s.id, minutes: 15) },
                                         resume: {}, extend: {})
                                .padding(.leading, 15)
                        }
                    }
                }
                if idleCount > 0 {
                    Button { openAgentControl() } label: {
                        Text("\(idleCount) idle").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !grantManager.grantGroups.isEmpty {
                CapsLabel("Permissions")
                ForEach(grantManager.grantGroups) { g in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(g.agent) · \(g.opLabel) · \(g.scopeLabel)"
                                 + (g.count > 1 ? " ×\(g.count)" : "")).font(.system(size: 12))
                            Text(g.status).font(.system(size: 11))
                                .foregroundStyle(g.status == "expired" ? Theme.muted : Theme.lime)
                        }
                        Spacer()
                        Button(g.count > 1 ? "Revoke all" : "Revoke") { grantManager.revokeGroup(g) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.coral)
                    }
                }
            }
        }
    }

    // Phase A item 5: one guaranteed way out. Pauses both walls for 15 minutes
    // and resumes by itself; while paused, a banner with the end time + Resume.
    @ViewBuilder private var globalPause: some View {
        PauseControl(state: grantManager.pauseState(nil), until: grantManager.pauseEnds(nil),
                     pauseLabel: "Pause Kai for 15 minutes",
                     pause: { grantManager.pauseAll(minutes: 15) },
                     resume: { grantManager.pauseAll(minutes: 0) },
                     extend: { grantManager.extendPause(nil) })
    }

    // Item 1: a persistent banner while any session is paused, with Resume.
    // (Pauses auto-resume and are capped at 1 day in the engine.)
    @ViewBuilder private var pauseBanner: some View {
        let paused = agents.pausedSessions
        ForEach(paused) { s in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.displayAgent)\(s.projectName.isEmpty ? "" : " · \(s.projectName)")")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                PauseControl(state: grantManager.pauseState(s.id), until: grantManager.pauseEnds(s.id),
                             pause: { grantManager.pauseSession(s.id, minutes: 15) },
                             resume: { grantManager.pauseSession(s.id, minutes: 0) },
                             extend: { grantManager.extendPause(s.id) })
            }
        }
    }

    private func openAgentControl() { open(.agentControl) }

    private var glow: Color {
        if alert != nil { return Theme.coral }
        if model.health == .problem { return Theme.coral }
        switch model.observedProtection(storageOn: storage.isOn, networkOn: wall.isOn) {
        case .protected: return Theme.lime
        case .partial: return Theme.amber
        case .notProtected: return Theme.coral
        }
    }

    private var background: some View {
        ZStack {
            Theme.ink
            RadialGradient(colors: [glow.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 320)
        }
        .animation(.easeInOut(duration: 0.6), value: glow)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("KaiLogo").resizable().frame(width: 26, height: 26).accessibilityHidden(true)
            Text("Kai").font(Theme.display(18))
            if !KaiInstance.isRelease { DevBadge() }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { open(.files) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 8) {
            StatTile(value: model.blockedThisWeek, label: "blocked this week", accent: model.blockedThisWeek > 0)
            StatTile(value: model.cleanedThisWeek, label: "requests cleaned")
            StatTile(value: model.reachedHosts.count, label: "hosts noticed")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var protection: some View {
        // Interim (before S5): the menu shows the two system walls only. Per-agent
        // toggles live in Settings → General (agents are on by default); the menu
        // stays focused on observed protection and what needs the user.
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CapsLabel("Protection")
                Spacer()
                Button("Agents") { open(.agentControl) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
            }
            Text("Covers every agent on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            NetworkCard()
            StorageCard()
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CapsLabel("Recent")
                Spacer()
                Button("See all") { open(.activity) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
            }
            let items = Array(model.importantEventGroups.prefix(3))
            if items.isEmpty {
                Text("Nothing blocked yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(items) { EventLine(event: $0.event, count: $0.count) }
            let hosts = model.reachedHosts.count
            if hosts > 0 {
                Button { open(.internet) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "eye").foregroundStyle(Theme.muted)
                        Text("\(hosts) new host\(hosts == 1 ? "" : "s") noticed (not blocked)")
                            .foregroundStyle(Theme.soft)
                        Spacer()
                        Text("Review").foregroundStyle(Theme.lime)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Edit Policy") { model.openPolicyFile() }
            Spacer()
            Button("Quit Kai") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.top, 2)
    }

    private func open(_ page: SettingsPage) {
        settingsPage = page.rawValue
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Hero

struct StatusHero: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall

    // U1: the hero shows OBSERVED wall enforcement (the walls' live OS state),
    // not configured policy. A Kai problem (policy unreadable, audit tampered)
    // still takes precedence.
    private var obs: AppModel.ObservedProtection {
        model.observedProtection(storageOn: storage.isOn, networkOn: wall.isOn)
    }
    private var color: Color {
        if model.health == .problem { return Theme.coral }
        switch obs {
        case .protected: return Theme.lime
        case .partial: return Theme.amber
        case .notProtected: return Theme.coral
        }
    }

    private var title: String {
        if model.health == .problem { return model.headline }
        return model.statusSentence(storageOn: storage.isOn, networkOn: wall.isOn)
    }

    private var subtitle: String {
        if model.health == .problem, let d = model.detailLine { return d }
        switch obs {
        case .protected: return "Both walls are enforcing on this Mac."
        case .partial: return "A wall is not enforcing — open Settings to check it."
        case .notProtected: return "No wall is enforcing. Agents are not restricted."
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(RadialGradient(colors: [color.opacity(0.22), .clear], center: .center,
                                             startRadius: 0, endRadius: 64))
                Circle().stroke(color.opacity(0.10), lineWidth: 10).padding(-5)
                Circle().stroke(color, lineWidth: 2)
                Image("KaiLogo").resizable().frame(width: 70, height: 70)
                    .saturation(obs == .protected ? 1 : 0.2)
            }
            .frame(width: 120, height: 120)
            .shadow(color: color.opacity(0.35), radius: 24)
            .padding(.top, 4)
            Text(title).font(Theme.display(24)).multilineTextAlignment(.center)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Phase A item 3: a hook block, as a card with a next step, never a dead
/// end. (Wall blocks stage their own decision card in Needs you.) The rule and
/// excerpt live behind "Why?"; "Open Activity" is where "Not a threat" lives.
struct BlockNotice: View {
    let event: AuditEvent
    let dismiss: () -> Void
    let details: () -> Void
    @State private var showWhy = false

    var body: some View {
        Card(stroke: Color(hex: 0x4A2A27)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "xmark.shield").foregroundStyle(Theme.coral)
                    Text("\(event.agentName) was stopped").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let d = event.date { Text(ago(d)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }
                Text((event.isPrompt ? "The prompt wasn't sent" : "The action didn't run")
                     + (event.detail.isEmpty ? "." : ": \(event.detail)."))
                    .font(.system(size: 12)).foregroundStyle(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
                if showWhy {
                    VStack(alignment: .leading, spacing: 4) {
                        if let x = event.excerpt {
                            Text(x).font(Theme.mono).foregroundStyle(Color(hex: 0xFFB4AC)).lineLimit(4)
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

struct StatTile: View {
    let value: Int
    let label: String
    var accent = false
    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(Theme.display(22)).foregroundStyle(accent ? Theme.lime : .white)
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }
}

struct AgentBadge: View {
    let agent: Agent
    private var style: (String, Color, Color) {
        switch agent.rawValue {
        case "claude": return ("C", Color(hex: 0x2B2420), Color(hex: 0xF0A27A))
        case "cursor": return ("Cu", Theme.raised, .white)
        case "codex": return ("Cx", Color(hex: 0x1E2A26), Color(hex: 0x7FE0B8))
        case "chrome": return ("Ch", Color(hex: 0x1E2638), Color(hex: 0x8AB4FF))
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
        if info.installed { return agent == .chrome ? "Checking chats" : "Protected" }
        return info.detected ? "Not protected" : "Not found on this Mac"
    }

    var body: some View {
        let info = model.agentInfo(agent)
        Card(padding: 10) {
            HStack(spacing: 12) {
                AgentBadge(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.system(size: 14, weight: .semibold))
                    if agent == .chrome && model.chromeNeedsExtension {
                        Button("Load the extension to finish") { model.openExtensionSetup() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.amber)
                            .help("Shows the extension folder (path copied) and opens chrome://extensions: turn on Developer mode, click Load unpacked, paste the path.")
                    } else {
                        Text(subtitle(info))
                            .font(.system(size: 12))
                            .foregroundStyle(info.broken || (!info.installed && info.detected) ? Theme.amber : Theme.muted)
                            .lineLimit(2)
                            .help(info.problem ?? "")
                    }
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

struct NetworkCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall

    private var subtitle: String {
        guard wall.isOn else { return wall.summary }
        switch model.policy?.switches["egress"] ?? "log" {
        case "block": return "Protect · agents reach only sites you allowed"
        case "off": return "Off"
        default: return "Watch · see where agents go, nothing blocked"
        }
    }

    private var warn: Bool {
        switch wall.state {
        case .needsApproval, .failed: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundStyle(Theme.lime)
                .frame(width: 32, height: 32)
                .background(Theme.lime.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Internet").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(warn ? Theme.amber : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Internet", isOn: Binding(get: { wall.isOn },
                                                 set: { $0 ? wall.turnOn() : wall.turnOff() }))
                .toggleStyle(KaiToggleStyle()).labelsHidden()
                .disabled(wall.state == .activating || wall.state == .checking)
        }
        .padding(10)
        .background(LinearGradient(colors: [Theme.surface, Color(hex: 0x1D2318)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(hex: 0x3A4420)))
    }
}

struct StorageCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var storage: StorageWall

    private var subtitle: String {
        switch storage.state {
        case .off: return "Off: agents can open your keys and passwords"
        case .on:
            switch model.policy?.switches["storage"] ?? "off" {
            case "block": return "Protect · agents can't open your keys and passwords"
            case "log": return "Watch · see what would be blocked"
            default: return "On"
            }
        default: return storage.summary
        }
    }

    private var warn: Bool {
        if case .needsApproval = storage.state { return true }
        if case .failed = storage.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 15)).foregroundStyle(Theme.lime)
                .frame(width: 32, height: 32)
                .background(Theme.lime.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Files").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(warn ? Theme.amber : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Files", isOn: Binding(get: { storage.isOn },
                                                 set: { $0 ? storage.turnOn() : storage.turnOff() }))
                .toggleStyle(KaiToggleStyle()).labelsHidden()
                .disabled(storage.state == .activating || storage.state == .checking)
        }
        .padding(10)
        .background(LinearGradient(colors: [Theme.surface, Color(hex: 0x1D2318)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(hex: 0x3A4420)))
    }
}

/// One line in the menu's recent list.
/// Item 2: one compact row per running session in the popover's Active now.
struct PopoverSessionRow: View {
    let session: SessionRow
    var grants: Int = 0
    private var badge: Color {
        session.enforcementShort == "Files + Internet" ? Theme.lime
        : session.enforcementShort == "seen only" ? Theme.muted : Theme.amber
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(badge).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName).font(.system(size: 13, weight: .medium))
                    Text(session.enforcementShort).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    if grants > 0 {
                        Text("\(grants) permission\(grants == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(Theme.lime)
                    }
                }
                if !session.topic.isEmpty {   // hook topic, or hidden — never the project twice
                    Text(session.topic).font(.system(size: 11)).foregroundStyle(Theme.soft).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(session.window)
                    if !session.activeLabel.isEmpty { Text("· \(session.activeLabel)") }
                }.font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
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
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(event.isBlock ? Theme.coral : Theme.amber).frame(width: 8, height: 8)
            Text(event.summary + (count > 1 ? "  ×\(count)" : ""))
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
            .foregroundStyle(Theme.ink)
            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let pause: () -> Void
    let resume: () -> Void
    let extend: () -> Void

    var body: some View {
        switch Int(state) {
        case KAI_PAUSE_ACTIVE:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(Theme.amber)
                    Text("Paused · resumes \(until.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon")")
                        .font(.system(size: 12))
                    Spacer()
                    Button("+15 min", action: extend)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Resume", action: resume)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.lime)
                }
                Text("Kai's own settings stay protected.").font(.system(size: 11)).foregroundStyle(Theme.muted)
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
            .help("Lets this through for 15 minutes, logged, then resumes by itself. Kai's own settings stay protected.")
        }
    }
}

/// A copy that isn't /Applications/Kai.app with the release signature: it
/// never hosts the control service, and says so.
struct DevBadge: View {
    var body: some View {
        Text("DEV").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.amber, in: Capsule())
            .help("A development copy: it doesn't run Kai's control service. The installed Kai in /Applications does.")
    }
}
