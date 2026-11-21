// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: a short onboarding, first launch only: what Kai connected, the
// Internet watching step (0.4.1's guided step), and Ask Kai with the model
// chip. Skip on every pane; never shown again once finished or skipped.
import SwiftUI

enum Onboarding {
    static let doneKey = "onboardingDone050"
    static var done: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    static func finish() { UserDefaults.standard.set(true, forKey: doneKey) }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wall: NetworkWall
    @ObservedObject private var agents = AgentsModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var pane = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image("KaiLogo").resizable().frame(width: 30, height: 30).accessibilityHidden(true)
                Text("Kai").font(.system(size: 18, weight: .bold))
                Spacer()
                Text("\(pane + 1) of 3").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Group {
                switch pane {
                case 0: connected
                case 1: internet
                default: askPane
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            HStack {
                Button("Skip") { close(openKai: false) }.buttonStyle(GhostButtonStyle())
                Spacer()
                if pane > 0 { Button("Back") { pane -= 1 }.buttonStyle(GhostButtonStyle()) }
                Button(pane == 2 ? "Open Kai" : "Continue") {
                    if pane == 2 { close(openKai: true) } else { pane += 1 }
                }
                .buttonStyle(LimeButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.ink)
        .task { await model.refresh(); await agents.refresh(); wall.refresh() }
    }

    private func close(openKai: Bool) {
        Onboarding.finish()
        if openKai {
            MainNav.shared.page = .now
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        dismiss()
    }

    private var connectedNames: [String] {
        (model.displayAgents(agents) ?? []).filter { $0.detected && ($0.hooks == "installed" || $0.hooks == "untrusted") }
            .map { $0.name }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            let names = connectedNames
            Text(names.isEmpty ? "Kai didn't find a supported agent yet."
                 : "Kai connected \(AutoConnectWords.joined(names.map(ActivityFeed.agentTitle))).")
                .font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(names, id: \.self) { n in
                    HStack(spacing: 6) { AgentLogo(agent: n, size: 28); Text(ActivityFeed.agentTitle(n)).font(.system(size: 13)) }
                }
            }
            Text(names.isEmpty
                 ? "When you install Claude Code, Cursor or Codex, Kai connects it by itself. You can turn each one off in Settings → Agents."
                 : "Kai checks what they read, edit and run, and keeps a list on this Mac only (no file contents). "
                   + "Turn any of them off in Settings → Agents.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if connectedNames.contains("codex") && model.codexNeedsTrust { CodexTrustRow() }
        }
    }

    private var internet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wall.isOn ? "Internet watching is on." : "Internet watching needs your OK.")
                .font(.system(size: 20, weight: .semibold))
            InternetSetupStep()
        }
    }

    private var askPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Kai anything about what your agents did.").font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Answers come from Kai's own records. Kai's templates work right away; a small model that runs on "
                 + "this Mac can word them better.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Answers:").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                ModelChooser(style: .chip)
            }
            Text("⌘K in the Kai window focuses Ask; ⌘J hides it.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }
}
