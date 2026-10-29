// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// The app reads `kai snapshot --json`. A Chats row without "hooks" once failed
// the whole decode and the popover showed no sessions. This decodes the REAL
// output of the built kai (argument 1) with the app's own types, then a copy
// with damaged rows and unknown values: one bad row never empties the list.
// Compiled with Sessions.swift only (tests/app/run_app_tests.sh).
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}

print("sessions: the app decodes the built kai's snapshot")
let real = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
do {
    let s = try SessionSnapshot.decode(real)
    let raw = try! JSONSerialization.jsonObject(with: real) as! [String: Any]
    let nS = (raw["sessions"] as? [Any])?.count ?? -1, nA = (raw["agents"] as? [Any])?.count ?? -1
    check(s.failures.isEmpty, "every row of the real output decodes (\(s.failures.first ?? "none failed"))")
    check(s.sessions.count == nS && s.agents.count == nA, "all \(nS) sessions and \(nA) agents kept")
    if CommandLine.arguments.count > 2 {
        let site = CommandLine.arguments[2]
        check(s.agents.contains { $0.name == site }, "the Chats row (\(site), no \"hooks\" field) decodes with the rest")
    }
} catch { check(false, "the real kai snapshot --json decodes: \(error)") }

// The shape that broke the popover: an agent row with no "hooks", plus a
// session with an unknown activity, one with no id, unknown fields and a
// non-object element.
let damaged = #"""
{"sessions":[
  {"id":"a","agent":"cursor","activity":"working","state":"active","kind":"session","workspaces":[],"source":"es","new_field":{"x":1}},
  {"id":"b","agent":"claude","activity":"thinking","state":"paused-by-future","last_active_utc":1},
  {"agent":"codex"},
  42,
  {"id":"c","agent":"codex","workspaces":[{"path":"/p","activity":"busy"},{"nopath":true}]}
 ],
 "agents":[{"name":"Claude Code","hooks":"installed"},{"name":"Chats","kind":"browser","coverage":"x","open_tabs":2},{"hooks":"x"}]}
"""#
do {
    let s = try SessionSnapshot.decode(Data(damaged.utf8))
    check(s.sessions.map(\.id) == ["a", "b", "c"], "bad session rows are skipped, the rest kept: \(s.sessions.map(\.id))")
    check(s.sessions.first?.isWorking == true, "a working Cursor app with no workspaces is working")
    check(s.sessions[1].activity == "unknown" && s.sessions[1].state == "unknown" && !s.sessions[1].isWorking,
          "unknown activity and state read \"unknown\", never working")
    check(s.sessions[1].activeLabel.contains("activity unknown"), "...and say so: \(s.sessions[1].activeLabel)")
    check(s.sessions[2].workspaces?.count == 1 && s.sessions[2].workspaces?.first?.activity == "unknown",
          "a bad workspace is skipped, an unknown workspace activity reads \"unknown\"")
    check(s.agents.map(\.name) == ["Claude Code", "Chats"], "an agent without hooks (Chats) decodes; one without a name is skipped")
    check(s.failures.count == 3, "the skipped rows are counted (2 sessions, 1 agent): \(s.failures.count)")
    check(s.sessions[1].isActive, "an unknown state stays listed, not moved to ended")
} catch { check(false, "damaged snapshot still decodes: \(error)") }

do { _ = try SessionSnapshot.decode(Data("{\"agents\":[]}".utf8)); check(false, "no sessions list is a failed source") }
catch { check(true, "no sessions list at all is reported as a failed source, not as 0 sessions") }

print(fails == 0 ? "sessions tests: all passed" : "sessions tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
