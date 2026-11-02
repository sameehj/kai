// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// The coverage list comes from live checks (the agent rows of `kai snapshot`,
// the extension's verified heartbeat level), never from configuration. Nov 2:
// plain words, colours that mean something, only agents on this Mac.
// Compiled with Sessions.swift and LiveCoverage.swift.
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func agent(_ name: String, _ hooks: String, detected: Bool = true) -> AgentRow {
    var a = AgentRow(name: name); a.hooks = hooks; a.detected = detected; return a
}

print("live coverage list")
let agents = [agent("claude", "installed"), agent("codex", "failing"), agent("cursor", "missing"),
              agent("gemini", "n/a", detected: false), agent("aider", "n/a", detected: false)]
var rows = LiveCoverage.rows(agents: agents, internetLevel: 1, protectAvailable: false)
func row(_ label: String) -> LiveCoverage.Row? { rows.first { $0.label == label } }
check(row("Claude Code")?.state == "Checking" && row("Claude Code")?.tone == .checking,
      "an agent whose hook self-test passes: Checking, green")
check(row("Codex")?.state == "Unhealthy" && row("Codex")?.tone == .problem, "a failing hook: Unhealthy, red (a real problem)")
check(row("Cursor")?.state == "Not installed" && row("Cursor")?.tone == .off, "hooks missing on a detected agent: Not installed, grey")
check(row("Gemini") == nil && row("Aider") == nil, "agents not on this Mac aren't listed")
check(LiveCoverage.others(agents: agents) == ["Gemini", "Aider"], "...they're the 'Other supported agents' (Settings only)")
check(row("Internet")?.state == "Watching, not blocking" && row("Internet")?.tone == .watching,
      "Internet level 1: 'Watching, not blocking', neutral (never red)")
check(row("Internet")?.info.contains("recorded, not blocked") == true, "...the longer explanation is behind the info button")
check(row("Encrypted request contents")?.state == "Not inspected" && row("Encrypted request contents")?.tone == .notIncluded,
      "encrypted contents: Not inspected, grey")
check(row("Files")?.state == "Not included" && row("Files")?.tone == .notIncluded, "Files: Not included, grey")
check(rows.allSatisfy { $0.state.count <= 22 }, "every state fits on one line at the popover's width (≤ 22 characters)")
rows = LiveCoverage.rows(agents: agents, internetLevel: -1, protectAvailable: false)
check(row("Internet")?.state == "Unknown" && row("Internet")?.tone == .off, "no verified heartbeat: Unknown, never watching by assumption")
rows = LiveCoverage.rows(agents: agents, internetLevel: 2, protectAvailable: false)
check(row("Internet")?.state == "Unhealthy" && row("Internet")?.tone == .problem,
      "a release app seeing a blocking heartbeat: Unhealthy")
rows = LiveCoverage.rows(agents: agents, internetLevel: 2, protectAvailable: true)
check(row("Internet")?.state == "Blocking (dev build)", "a developer build in Protect says so")
rows = LiveCoverage.rows(agents: agents, internetLevel: 0, protectAvailable: false)
check(row("Internet")?.state == "Off", "Internet off: Off")
rows = LiveCoverage.rows(agents: [], internetLevel: 1, protectAvailable: false)
check(row("Agent checks")?.state == "Unknown", "no agent rows: Unknown, not 'none installed'")
check(!rows.contains { $0.state.lowercased().contains("protected") }, "no row says protected")
check(LiveCoverage.headlineTone(agents: [agent("claude", "installed")], internetLevel: 1) == .checking,
      "headline: checking agents and Internet watching is green, never red")
check(LiveCoverage.headlineTone(agents: [agent("claude", "failing")], internetLevel: 1) == .problem,
      "headline: red only for a real problem (a check unhealthy or an agent blocked)")

print("blocked banner (STEP 2c)")
var broken = AgentRow(name: "claude"); broken.hooks = "failing"; broken.detected = true
broken.detail = "Kai's program is missing (/usr/local/bin/kai): the agent is blocked until Kai is reinstalled"
var fine = AgentRow(name: "codex"); fine.hooks = "installed"
var odd = AgentRow(name: "cursor"); odd.hooks = "failing"; odd.detail = "Kai's hook didn't block a test request (exit 1)"
let banners = LiveCoverage.blocked(agents: [broken, fine, odd])
check(banners.map(\.agent) == ["Claude Code", "Cursor"], "every agent whose checks can't run gets a banner (\(banners.map(\.agent)))")
check(banners.first?.title == "Claude Code is blocked: Kai's checks can't run", "the banner names the agent and the cause")
check(banners.first?.actions == ["Repair", "Turn off checks for Claude Code"], "...with Repair and Turn off checks")
check(LiveCoverage.blocked(agents: [fine]).isEmpty, "healthy agents: no banner")

print("session tab names (Nov 2)")
var s = SessionRow(id: "a", agent: "claude"); s.tty = "/dev/ttys001"
check(s.tab == "Terminal tab 1", "ttys001 reads 'Terminal tab 1' (\(s.tab))")
s.tty = "ttys012"
check(s.tab == "Terminal tab 12", "ttys012 reads 'Terminal tab 12'")
s.tty = ""
check(s.tab == "", "no tty: no tab")

print(fails == 0 ? "coverage list tests: all passed" : "coverage list tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
