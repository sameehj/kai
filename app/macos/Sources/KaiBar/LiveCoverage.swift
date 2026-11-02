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
    struct Row: Equatable { let label: String; let state: String; let good: Bool }

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

    /// internetLevel: the heartbeat level (2 blocking, 1 watching, 0 off, -1 unconfirmed).
    static func rows(agents: [AgentRow], internetLevel: Int, protectAvailable: Bool) -> [Row] {
        var out: [Row] = []
        if agents.isEmpty {
            out.append(Row(label: "Agent checks", state: "unknown (Kai can't list agents right now)", good: false))
        }
        for a in agents {
            switch a.hooks {
            case "installed": out.append(Row(label: title(a.name), state: "enforcing where invoked", good: true))
            case "failing": out.append(Row(label: title(a.name), state: "unhealthy", good: false))
            case "missing", "not found": out.append(Row(label: title(a.name), state: "not installed", good: false))
            default: out.append(Row(label: title(a.name), state: "no Kai checks", good: false))
            }
        }
        let internet: Row
        switch internetLevel {
        case 2:
            internet = protectAvailable
                ? Row(label: "Internet", state: "blocking unknown hosts (developer build)", good: true)
                : Row(label: "Internet", state: "unhealthy (reports blocking, which this release never does)", good: false)
        case 1: internet = Row(label: "Internet", state: "watching (connections Kai observes are recorded, not blocked)", good: true)
        case 0: internet = Row(label: "Internet", state: "off", good: false)
        default: internet = Row(label: "Internet", state: "unknown (Kai can't confirm the wall's mode)", good: false)
        }
        out.append(internet)
        out.append(Row(label: "Encrypted request contents", state: "not inspected", good: false))
        out.append(Row(label: "Files", state: "not included in this release", good: false))
        return out
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
