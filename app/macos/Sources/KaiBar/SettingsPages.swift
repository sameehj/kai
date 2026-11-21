// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5 Settings pages that were window pages or sub-sections before:
// Agents (0.4's Agents page: the switches, coverage, the Codex /hooks step),
// Rules (exceptions and checks, which lived under Decisions and Advanced),
// and Ask Kai (the same model control as the chat's model chip).
import SwiftUI
import KaiCore

enum AgentTrademarks {
    static let line = "Claude is a trademark of Anthropic. Cursor is a trademark of Anysphere. Codex and OpenAI "
        + "are trademarks of OpenAI. Kai is not affiliated with or endorsed by them."
}

struct AgentsSettingsPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var agents = AgentsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(icon: "person.2", title: "Agents",
                       subtitle: "Kai's connection to each agent on this Mac, and what each one reports.")
            if let note = model.connectedNote { ConnectedNote(text: note) }
            CodexTrustRow()
            let rows = model.displayAgents(agents)
            let found = (rows ?? []).filter(\.detected)
            if rows == nil, let err = agents.sourceError {
                Text("Kai can't list agents right now: \(err)").font(.system(size: 12)).foregroundStyle(Theme.amber)
            } else if rows == nil {
                ProgressView().controlSize(.small)
            } else if found.isEmpty {
                Text("No supported agent found on this Mac.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(found) { a in AgentSettingsRow(agent: a) }
            }
            Text("Kai connects every agent it finds on this Mac. On adds Kai's checks to the agent's settings file "
                 + "(its hooks) and keeps a backup; Off removes them, and Kai won't connect that agent again on its own. "
                 + "Restart open agent sessions to pick up a change. Connected is about Kai's integration only; "
                 + "working means a connected agent ran something in the last 15 minutes.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentSettingsRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var agents = AgentsModel.shared
    let agent: AgentRow

    var body: some View {
        let (state, tone) = Self.state(agent, agents, codexNeedsTrust: model.codexNeedsTrust)
        Card(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                AgentLogo(agent: agent.name, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LiveCoverage.title(agent.name)).font(.system(size: 14, weight: .semibold))
                    Text(state).font(.system(size: 12)).foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ActivityFeed.coverage(agent.name)).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let ag = Agent(rawValue: agent.name) {
                    if agent.hooks == "failing" {
                        Button("Reconnect") { model.setAgent(ag, enabled: true) }.buttonStyle(LimeButtonStyle(subtle: true))
                    }
                    Toggle("On", isOn: Binding(get: { agent.hooks != "missing" && agent.hooks != "not found" },
                                               set: { model.setAgent(ag, enabled: $0) }))
                        .toggleStyle(KaiToggleStyle()).labelsHidden()
                        .disabled(model.busy || model.status == nil)
                        .help("On: Kai's hooks are in \(ag.title)'s settings. Off: Kai leaves it alone "
                              + "and won't connect it again on its own.")
                }
            }
        }
    }

    @MainActor
    static func state(_ a: AgentRow, _ agents: AgentsModel, codexNeedsTrust: Bool) -> (String, Color) {
        let title = LiveCoverage.title(a.name)
        let working = agents.workingNow.filter { $0.displayAgent == title }.count
        let running = agents.interactiveSessions.contains { $0.isActive && $0.displayAgent == title }
        if a.hooks == "untrusted" || (a.name == "codex" && a.hooks == "installed" && codexNeedsTrust) {
            return ("Connected · not checked until you run /hooks in Codex once", Theme.amber)
        }
        if a.hooks == "installed" {
            return (working > 0 ? "Connected · \(working) working" : running ? "Connected · idle" : "Connected · not running today",
                    Theme.muted)
        }
        if a.hooks == "failing" { return ("Not working: \(a.detail ?? "Kai's hook didn't answer a test request.")", Theme.amber) }
        if AppModel.userTurnedOff(a.name) { return ("Off · you turned it off", Theme.muted) }
        if running { return ("Not connected · running · activity unknown", Theme.amber) }
        return ("Not connected · activity unavailable", Theme.amber)
    }
}

struct RulesSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "list.bullet.clipboard", title: "Rules",
                       subtitle: "What Kai's checks do, and the exceptions you made. Stops are in Activity → Stops.")
            ProtectionPage()
        }
    }
}

struct AskSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(icon: "bubble.left.and.text.bubble.right", title: "Ask Kai",
                       subtitle: "Answers come from Kai's records. A model is optional and only rewords them.")
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Model").font(.system(size: 14, weight: .semibold))
                    Text("The same choice as the model menu next to the Ask button. A model only picks what kind of "
                         + "question you asked (from a fixed list) and rewords Kai's answer. It never decides "
                         + "anything, can't add buttons or change settings, and sees only your question and Kai's "
                         + "short answer. Coverage limits are always shown by Kai, not by the model.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    ModelChooser(style: .settings)
                }
            }
        }
    }
}
