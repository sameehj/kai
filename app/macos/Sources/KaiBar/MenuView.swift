// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import SwiftUI

/// The panel that drops down from the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @EnvironmentObject var storage: StorageWall
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPage") private var settingsPage = SettingsPage.general.rawValue
    @State private var dismissedBlock: String?
    @StateObject private var grantManager = GrantManager()

    private var alert: AuditEvent? {
        guard let b = model.freshBlock, b.id != dismissedBlock else { return nil }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let msg = model.errorMessage { ErrorBanner(message: msg) { model.errorMessage = nil } }
            if let b = alert {
                BlockedHero(event: b,
                            dismiss: { withAnimation { dismissedBlock = b.id } },
                            details: { open(.activity) })
            } else {
                StatusHero()
                stats
            }
            protection
            ApprovalsSection(manager: grantManager)
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
        .task { await model.refresh(); wall.refresh() }
    }

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
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { open(.general) } label: {
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
                CapsLabel("System protection")
                Spacer()
                Button("Agents") { openWindow(id: "agents"); NSApp.activate(ignoringOtherApps: true) }
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
                Button { open(.network) } label: {
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
        return model.observedHeadline(storageOn: storage.isOn, networkOn: wall.isOn)
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

struct BlockedHero: View {
    let event: AuditEvent
    let dismiss: () -> Void
    let details: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.coral.opacity(0.22), .clear], center: .center,
                                             startRadius: 0, endRadius: 64))
                Circle().stroke(Theme.coral.opacity(0.12), lineWidth: 10).padding(-5)
                    .scaleEffect(pulse ? 1.08 : 1)
                Circle().stroke(Theme.coral, lineWidth: 2)
                Image(systemName: "xmark.shield").font(.system(size: 50, weight: .light))
                    .foregroundStyle(Theme.coral)
            }
            .frame(width: 120, height: 120)
            .shadow(color: Theme.coral.opacity(0.4), radius: 24)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            Text("Kai stopped \(event.agentName)").font(Theme.display(22)).multilineTextAlignment(.center)
            Text(event.isPrompt ? "The prompt wasn't sent." : event.isNetwork ? "The connection was dropped."
                                                             : "The action didn't run.")
                .font(.system(size: 13)).foregroundStyle(Theme.soft)

            Card(stroke: Color(hex: 0x4A2A27)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CapsLabel("What happened")
                        Spacer()
                        if let d = event.date { Text(ago(d)).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    }
                    Text(event.excerpt ?? (event.detail.isEmpty ? event.rule : event.detail))
                        .font(Theme.mono).foregroundStyle(Color(hex: 0xFFB4AC)).lineLimit(4)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
                    if event.excerpt != nil && !event.detail.isEmpty {
                        Text(event.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    if !event.rule.isEmpty {
                        Label(event.rule, systemImage: "circle.fill")
                            .labelStyle(DotLabelStyle(color: Theme.coral))
                            .font(.system(size: 13))
                    }
                    HStack(spacing: 8) {
                        Button("Got it", action: dismiss).buttonStyle(WhiteButtonStyle())
                        Button("View details", action: details).buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        case "block": return "Block mode · only allowed hosts"
        case "off": return "Paused in policy"
        default: return "Log mode · nothing blocked"
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
                Text("Network wall").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(warn ? Theme.amber : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Network wall", isOn: Binding(get: { wall.isOn },
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
        case .off: return "Off: agents can still open protected files directly"
        case .on:
            switch model.policy?.switches["storage"] ?? "off" {
            case "block": return "Block mode · protected files denied to agents"
            case "log": return "Watching · logs what it would block"
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
                Text("Storage wall").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(warn ? Theme.amber : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Storage wall", isOn: Binding(get: { storage.isOn },
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
