// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Nov 1 corrective change, step 6: what Kai covers right now, in one list,
// from live checks only: the agent rows `kai snapshot` measured (hook
// installed and its self-test passing), and the Internet wall's level from
// the extension's verified heartbeat. Never from configuration; when a check
// can't confirm a state, the row says unknown. Foundation only, tested by
// tests/app/coverage_main.swift.
import Foundation

enum LiveCoverage {
    /// Nov 2: colours mean something. Green: checking. Neutral: watching.
    /// Grey: off, not included, not inspected or unknown. Red only for a real
    /// problem (a check unhealthy, an agent blocked by a broken hook).
    enum Tone { case checking, watching, off, notIncluded, problem }
    struct Row: Equatable { let label: String; let state: String; let tone: Tone; let info: String }

    /// The agents Kai has checks for (the compact list shows only these).
    static let integrated: Set<String> = ["claude", "codex", "cursor", "Claude Code", "Codex", "Cursor"]

    static func title(_ name: String) -> String {
        switch name {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// Only agents found on this Mac; short states (one line at the popover's
    /// width), the explanation behind the info button.
    /// internetLevel: the heartbeat level (2 blocking, 1 watching, 0 off, -1 unconfirmed).
    static func rows(agents: [AgentRow], internetLevel: Int, protectAvailable: Bool) -> [Row] {
        var out: [Row] = []
        if agents.isEmpty {
            out.append(Row(label: "Agent checks", state: "Unknown", tone: .off,
                           info: "Kai can't list agents right now."))
        }
        for a in agents where a.detected {
            switch a.hooks {
            case "installed":
                out.append(Row(label: title(a.name), state: "Checking", tone: .checking,
                               info: "Kai's checks run when \(title(a.name)) calls them: its tool calls and prompts."))
            case "failing":
                out.append(Row(label: title(a.name), state: "Unhealthy", tone: .problem,
                               info: a.detail ?? "Kai's hook didn't answer. Open Kai and click Repair."))
            default:
                out.append(Row(label: title(a.name), state: "Not installed", tone: .off,
                               info: "Kai's checks aren't installed for \(title(a.name)). Run kai install \(a.name)."))
            }
        }
        let internet: Row
        switch internetLevel {
        case 2:
            internet = protectAvailable
                ? Row(label: "Internet", state: "Blocking (dev build)", tone: .checking,
                      info: "A developer build in Protect: unknown hosts are blocked.")
                : Row(label: "Internet", state: "Unhealthy", tone: .problem,
                      info: "The Internet wall reports blocking, which this release never does.")
        case 1: internet = Row(label: "Internet", state: "Watching, not blocking", tone: .watching,
                               info: "Connections Kai observes are recorded, not blocked. Blocking arrives in the next release.")
        case 0: internet = Row(label: "Internet", state: "Off", tone: .off, info: "The Internet wall is off.")
        default: internet = Row(label: "Internet", state: "Unknown", tone: .off,
                                info: "Kai can't confirm the Internet wall's mode.")
        }
        out.append(internet)
        out.append(Row(label: "Encrypted request contents", state: "Not inspected", tone: .notIncluded,
                       info: "Kai sees where encrypted connections go, not what they send."))
        out.append(Row(label: "Files", state: "Not included", tone: .notIncluded,
                       info: "Files protection is not included in this release."))
        return out
    }

    /// Agents Kai supports that aren't on this Mac: Settings, collapsed.
    static func others(agents: [AgentRow]) -> [String] { agents.filter { !$0.detected }.map { title($0.name) } }

    /// The popover headline's colour: red only for a real problem.
    static func headlineTone(agents: [AgentRow], internetLevel: Int) -> Tone {
        if agents.contains(where: { $0.detected && $0.hooks == "failing" }) { return .problem }
        if agents.contains(where: { $0.detected && $0.hooks == "installed" }) { return .checking }
        return internetLevel == 1 ? .watching : .off
    }

    /// STEP 2c: an agent whose Kai hooks are installed but don't answer (the
    /// program they run is missing or broken) is blocked: say so at the top of
    /// the popover, with Repair and Turn off checks.
    struct Banner: Equatable { let agentKey: String; let agent: String; let title: String; let detail: String; let actions: [String] }

    static func blocked(agents: [AgentRow]) -> [Banner] {
        agents.filter { $0.hooks == "failing" }.map { a in
            let name = title(a.name)
            return Banner(agentKey: a.name.lowercased() == "claude code" ? "claude" : a.name.lowercased(), agent: name,
                          title: "\(name) is blocked: Kai's checks can't run",
                          detail: a.detail ?? "Kai's hook didn't answer.",
                          actions: ["Repair", "Turn off checks for \(name)"])
        }
    }
}
