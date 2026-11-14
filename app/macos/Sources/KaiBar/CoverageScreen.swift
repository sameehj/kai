// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.3: what each agent's checks see, opened from the popover's coverage
// line. Live state on top (LiveCoverageList: measured hooks, the Internet
// heartbeat); under it, per agent, three fixed groups from docs/COVERAGE.md:
// Checked (Kai can stop it before it runs), Observed only (recorded, left to
// the agent), Not covered (Kai never sees it). Never "protected".
import SwiftUI

enum CoverageText {
    struct Groups { let checked: [String]; let observed: [String]; let notCovered: [String] }

    /// What no agent's hooks see: the agent's own children and editor
    /// extensions run no hooks.
    static let neverSeen = ["Programs and subprocesses the agent starts (the hook sees only the command that starts them)",
                            "Scripts the agent writes and runs, and what they open or send",
                            "Editor extensions acting on their own",
                            "Background and detached processes",
                            "Tool results and the agent's own model traffic"]
    static let internet = "Internet connections, when Internet (preview) is on: recorded, never blocked"

    static func groups(_ agent: String) -> Groups {
        switch agent {
        case "claude", "Claude Code":
            return Groups(checked: ["Files its Read, Write and Edit tools open",
                                    "Shell commands: protected paths, uploads, screen and app control",
                                    "Prompts you submit (secrets)",
                                    "Its web fetch (secrets in the URL)",
                                    "Destructive MCP tools, and ones that name another host",
                                    "Its screenshot and computer-use tools"],
                          observed: ["Routine MCP tool calls (left to Claude Code's own approval)", internet],
                          notCovered: neverSeen)
        case "codex", "Codex":
            return Groups(checked: ["Shell commands: protected paths, uploads, screen and app control",
                                    "Prompts you submit (secrets)",
                                    "Destructive MCP tools, and ones that name another host",
                                    "Its screenshot and computer-use tools"],
                          observed: ["Routine MCP tool calls (left to Codex's own approval)", internet],
                          notCovered: ["Codex reports no file-tool or web-fetch events"] + neverSeen)
        case "cursor", "Cursor":
            return Groups(checked: ["Files its read tool opens",
                                    "Shell commands: protected paths, uploads, screen and app control",
                                    "Prompts you submit (secrets)",
                                    "MCP tool arguments (secrets only; Cursor doesn't name the server)",
                                    "Its screenshot tool"],
                          observed: [internet],
                          notCovered: ["Files Cursor's editor writes (no write event)", "Its web fetch (no event)"] + neverSeen)
        default:
            return Groups(checked: [], observed: [], notCovered: ["Kai has no checks for this agent"] + neverSeen)
        }
    }
}

struct CoverageScreen: View {
    @ObservedObject private var agents = AgentsModel.shared

    private var shown: [String] {
        let found = agents.agents.filter { $0.detected && LiveCoverage.integrated.contains($0.name) }.map(\.name)
        return found.isEmpty ? ["claude", "codex", "cursor"] : found
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiveCoverageList()
                Text("Kai's checks run inside each agent (its hooks) and with your permissions. They see only what the agent reports.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(shown, id: \.self) { a in
                    let g = CoverageText.groups(a)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LiveCoverage.title(a)).font(.system(size: 13, weight: .semibold))
                        group("Checked", g.checked, Theme.lime)
                        group("Observed only", g.observed, Theme.soft)
                        group("Not covered", g.notCovered, Theme.muted)
                    }
                    Divider()
                }
            }
            .padding(14)
        }
        .frame(width: 360).frame(maxHeight: 520)
    }

    @ViewBuilder private func group(_ title: String, _ items: [String], _ color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                }
                ForEach(items, id: \.self) { t in
                    Text("· " + t).font(.system(size: 11)).foregroundStyle(Theme.soft)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 12)
                }
            }
        }
    }
}
