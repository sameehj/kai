// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import SwiftUI

/// The panel that drops down from the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let msg = model.errorMessage { ErrorBanner(message: msg) { model.errorMessage = nil } }
            Divider()
            agents
            Divider()
            activity
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.system(size: 26))
                .foregroundStyle(healthColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline).font(.headline)
                if let d = model.detailLine {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    let c = model.todayCounts
                    Text("Today: \(c.blocked) blocked, \(c.warned) warnings")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var healthColor: Color {
        switch model.health {
        case .protecting: return .green
        case .partial: return .yellow
        case .off: return .secondary
        case .problem: return .red
        case .unknown: return .secondary
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Agents")
            ForEach(Agent.allCases) { a in
                AgentToggle(agent: a)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Recent activity")
            if model.events.isEmpty {
                Text("Nothing blocked yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.events.prefix(5)) { e in EventRow(event: e, compact: true) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Edit Policy") { model.openPolicyFile() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

struct AgentToggle: View {
    @EnvironmentObject var model: AppModel
    let agent: Agent

    var body: some View {
        let info = model.agentInfo(agent)
        Toggle(isOn: Binding(get: { info.installed },
                             set: { model.setAgent(agent, enabled: $0) })) {
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.title)
                Text(info.installed ? "Protected" : (info.detected ? "Not protected" : "Not found on this Mac"))
                    .font(.caption)
                    .foregroundStyle(info.installed ? Color.secondary : (info.detected ? Color.orange : Color.secondary))
            }
        }
        .toggleStyle(.switch)
        .disabled(model.busy || model.status == nil)
    }
}

struct EventRow: View {
    let event: AuditEvent
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.isBlock ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(event.isBlock ? .red : .orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(compact ? .callout : .body)
                    .lineLimit(compact ? 2 : nil)
                HStack(spacing: 6) {
                    if let d = event.date {
                        Text(d, style: .relative) + Text(" ago")
                    }
                    if !event.rule.isEmpty { Text("· \(event.rule)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
