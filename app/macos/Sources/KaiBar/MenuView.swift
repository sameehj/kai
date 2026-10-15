// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import SwiftUI

/// The panel that drops down from the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsPage") private var settingsPage = SettingsPage.general.rawValue
    @State private var dismissedBlock: String?

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
        switch model.health {
        case .protecting: return Theme.lime
        case .partial: return Theme.amber
        case .problem: return Theme.coral
        case .off, .unknown: return Theme.muted
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
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Protection")
            ForEach(Agent.allCases) { AgentCard(agent: $0) }
            NetworkCard()
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
            let items = Array(model.importantEvents.prefix(3))
            if items.isEmpty {
                Text("Nothing blocked yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(items) { EventLine(event: $0) }
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

    private var color: Color {
        switch model.health {
        case .protecting: return Theme.lime
        case .partial: return Theme.amber
        case .problem: return Theme.coral
        case .off, .unknown: return Theme.muted
        }
    }

    private var title: String {
        switch model.health {
        case .protecting: return "All protected"
        case .partial: return "Partly protected"
        case .off: return "Protection is off"
        case .unknown: return "Checking…"
        case .problem: return model.headline
        }
    }

    private var subtitle: String {
        if let d = model.detailLine { return d }
        let names = Agent.allCases.filter { model.installed($0) }.map(\.title)
        let covered = names.isEmpty ? "No agent is protected yet."
            : ListFormatter.localizedString(byJoining: names) + (names.count == 1 ? " is covered." : " are covered.")
        return covered + (wall.isOn ? "\nNetwork wall is watching agent traffic." : "")
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(RadialGradient(colors: [color.opacity(0.22), .clear], center: .center,
                                             startRadius: 0, endRadius: 64))
                Circle().stroke(color.opacity(0.10), lineWidth: 10).padding(-5)
                Circle().stroke(color, lineWidth: 2)
                Image("KaiLogo").resizable().frame(width: 70, height: 70)
                    .saturation(model.health == .protecting ? 1 : 0.2)
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
            Text("Nothing left your Mac.").font(.system(size: 13)).foregroundStyle(Theme.soft)

            Card(stroke: Color(hex: 0x4A2A27)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CapsLabel("What happened")
                        Spacer()
                        if let d = event.date { Text(ago(d)).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    }
                    Text(event.detail.isEmpty ? event.rule : event.detail)
                        .font(Theme.mono).foregroundStyle(Color(hex: 0xFFB4AC))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        let info = model.agentInfo(agent)
        Card(padding: 10) {
            HStack(spacing: 12) {
                AgentBadge(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.system(size: 14, weight: .semibold))
                    Text(info.installed ? "Hooks on" : (info.detected ? "Not protected" : "Not found on this Mac"))
                        .font(.system(size: 12))
                        .foregroundStyle(!info.installed && info.detected ? Theme.amber : Theme.muted)
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

/// One line in the menu's recent list.
struct EventLine: View {
    let event: AuditEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(event.isBlock ? Theme.coral : Theme.amber).frame(width: 8, height: 8)
            Text(event.summary).font(.system(size: 13)).foregroundStyle(Theme.soft)
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
