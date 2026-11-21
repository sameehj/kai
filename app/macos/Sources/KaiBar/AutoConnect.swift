// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.4.1: Kai connects every agent it detects, on by default. The user turns
// one off in Settings → Agents; that choice is kept (UserDefaults
// "agentsUserDisabled") and Kai never reconnects it on its own. A newly
// detected agent (Cursor installed later) is connected on the next refresh.
// Setup (`kai install <agent>`) is idempotent and runs as the signed-in user,
// from the app.
//
// Codex runs hooks only after the user trusts them once (/hooks in Codex).
// Until Kai has seen Codex call its hook, Kai never says Codex is checked.
//
// Foundation only: compiled into the app tests.
import Foundation

enum AutoConnect {
    static let disabledKey = "agentsUserDisabled"

    /// One agent as `kai status --json` reports it.
    struct AgentState: Equatable {
        var key: String
        var detected: Bool
        var installed: Bool
        /// When the agent last called Kai's hook (0 = never, nil = unknown).
        var lastHook: Double? = nil
    }

    /// Agents to connect now.
    /// - previouslyDetected: what the last pass saw as detected; nil on the
    ///   first pass of this launch (then every detected agent is considered).
    /// - Later passes connect only agents whose `detected` flipped to true,
    ///   so a failed setup isn't retried every 10 seconds.
    static func plan(_ agents: [AgentState], disabled: Set<String>, previouslyDetected: Set<String>?) -> [String] {
        agents.filter { a in
            guard a.detected, !a.installed, !disabled.contains(a.key) else { return false }
            guard let before = previouslyDetected else { return true }
            return !before.contains(a.key)
        }.map(\.key)
    }

    /// The user's switch: off adds the agent to the opt-out list, on removes it.
    static func disabled(_ current: [String], agent: String, enabled: Bool) -> [String] {
        var s = current.filter { $0 != agent }
        if !enabled { s.append(agent) }
        return s.sorted()
    }

    /// "Kai connected Claude Code, Cursor and Codex." Only the agents that
    /// were detected and are now connected; nil when there are none.
    static func connectedLine(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return "Kai connected " + joined(titles) + "."
    }

    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    /// Codex: hooks installed but Kai has no record of Codex calling them, so
    /// its one-time trust step is (probably) not done. Unknown counts as not done.
    static func codexNeedsTrust(_ codex: AgentState?) -> Bool {
        guard let c = codex, c.detected, c.installed else { return false }
        return (c.lastHook ?? 0) <= 0
    }
    static let codexTrustLine = "Codex: open Codex and run /hooks once to trust Kai."

    /// The popover's agent list: "Looking for agents…" for at most `grace`
    /// seconds after launch, then the real state.
    /// - snapshotCount: detected agents from `kai snapshot` (nil until it lands).
    /// - statusCount: detected agents from `kai status` (the fallback after
    ///   the grace period; nil while unknown).
    /// Never "No agents found" when neither source could be read: that's
    /// `.unreadable`, said as such.
    enum ListState: Equatable { case looking, noneFound, list, unreadable }
    static func listState(snapshotCount: Int?, statusCount: Int?, sinceLaunch: TimeInterval,
                          grace: TimeInterval = 5) -> ListState {
        if let n = snapshotCount { return n == 0 ? .noneFound : .list }
        if sinceLaunch < grace { return .looking }
        if let n = statusCount { return n == 0 ? .noneFound : .list }
        return .unreadable
    }
}
