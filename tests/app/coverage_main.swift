// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Nov 1 corrective change, step 6: the coverage list comes from live checks
// (the agent rows of `kai snapshot`, the extension's verified heartbeat level),
// never from configuration. Compiled with Sessions.swift and LiveCoverage.swift.
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func agent(_ name: String, _ hooks: String) -> AgentRow { var a = AgentRow(name: name); a.hooks = hooks; return a }

print("live coverage list")
let agents = [agent("Claude Code", "installed"), agent("Codex", "failing"), agent("Cursor", "not found"),
              agent("Gemini CLI", "missing")]
var rows = LiveCoverage.rows(agents: agents, internetLevel: 1, protectAvailable: false)
func state(_ label: String) -> String? { rows.first { $0.label == label }?.state }
check(state("Claude Code") == "enforcing where invoked", "an agent whose hook self-test passes: enforcing where invoked")
check(state("Codex") == "unhealthy", "a failing hook: unhealthy")
check(state("Cursor") == "not installed" && state("Gemini CLI") == "not installed", "missing or not found: not installed")
check(state("Internet") == "watching (connections Kai observes are recorded, not blocked)", "Internet level 1: watching")
check(state("Encrypted request contents") == "not inspected", "encrypted contents: not inspected")
check(state("Files") == "not included in this release", "Files: not included in this release")
rows = LiveCoverage.rows(agents: agents, internetLevel: -1, protectAvailable: false)
check(state("Internet") == "unknown (Kai can't confirm the wall's mode)", "no verified heartbeat: unknown, never watching by assumption")
rows = LiveCoverage.rows(agents: agents, internetLevel: 2, protectAvailable: false)
check(state("Internet") == "unhealthy (reports blocking, which this release never does)",
      "a release app seeing a blocking heartbeat: unhealthy, not 'protected'")
rows = LiveCoverage.rows(agents: agents, internetLevel: 2, protectAvailable: true)
check(state("Internet") == "blocking unknown hosts (developer build)", "a developer build in Protect says so")
rows = LiveCoverage.rows(agents: agents, internetLevel: 0, protectAvailable: false)
check(state("Internet") == "off", "Internet off: off")
rows = LiveCoverage.rows(agents: [], internetLevel: 1, protectAvailable: false)
check(state("Agent checks") == "unknown (Kai can't list agents right now)", "no agent rows: unknown, not 'none installed'")
check(!rows.contains { $0.state.lowercased().contains("protected") }, "no row says protected")

print("blocked banner (STEP 2c)")
var broken = AgentRow(name: "claude"); broken.hooks = "failing"
broken.detail = "Kai's program is missing (/usr/local/bin/kai): the agent is blocked until Kai is reinstalled"
var fine = AgentRow(name: "codex"); fine.hooks = "installed"
var odd = AgentRow(name: "cursor"); odd.hooks = "failing"; odd.detail = "Kai's hook didn't block a test request (exit 1)"
let banners = LiveCoverage.blocked(agents: [broken, fine, odd])
check(banners.map(\.agent) == ["Claude Code", "Cursor"], "every agent whose checks can't run gets a banner (\(banners.map(\.agent)))")
check(banners.first?.title == "Claude Code is blocked: Kai's checks can't run", "the banner names the agent and the cause")
check(banners.first?.actions == ["Repair", "Turn off checks for Claude Code"], "...with Repair and Turn off checks")
check(LiveCoverage.blocked(agents: [fine]).isEmpty, "healthy agents: no banner")

print(fails == 0 ? "coverage list tests: all passed" : "coverage list tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
