// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// The app reads `kai snapshot --json`. An agent row without "hooks" once failed
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
 "agents":[{"name":"Claude Code","hooks":"installed"},{"name":"Unlisted agent","kind":"cli","coverage":"x"},{"hooks":"x"}]}
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
    check(s.agents.map(\.name) == ["Claude Code", "Unlisted agent"], "an agent row without hooks decodes; one without a name is skipped")
    check(s.failures.count == 3, "the skipped rows are counted (2 sessions, 1 agent): \(s.failures.count)")
    check(s.sessions[1].isActive, "an unknown state stays listed, not moved to ended")
} catch { check(false, "damaged snapshot still decodes: \(error)") }

do { _ = try SessionSnapshot.decode(Data("{\"agents\":[]}".utf8)); check(false, "no sessions list is a failed source") }
catch { check(true, "no sessions list at all is reported as a failed source, not as 0 sessions") }

// Step 6: session names. What the session is about (topic, else project
// folder, else workspaces) plus the terminal tab; never two identical names,
// never the agent's own name ("Cursor · Cursor").
print("sessions: names")
func row(_ id: String, _ agent: String, project: String = "", tty: String = "", topic: String = "",
         host: String = "", started: Int = 0, ws: [String]? = nil) -> SessionRow {
    var r = SessionRow(id: id, agent: agent)
    r.project = project; r.tty = tty; r.topic = topic; r.hostApp = host; r.startedUtc = started
    if let ws {
        let j = "[" + ws.map { "{\"path\":\"\($0)\"}" }.joined(separator: ",") + "]"
        r.workspaces = try! JSONDecoder().decode([SessionRow.Workspace].self, from: Data(j.utf8))
    }
    return r
}
var named = [
    row("c1", "claude", project: "/u/src/kai", tty: "/dev/ttys000"),
    row("c2", "claude", project: "/u/src/kai", tty: "/dev/ttys001"),
    row("c3", "claude", project: "/u/src/web", tty: "ttys003", topic: "Fix the login page"),
    row("c4", "claude", project: "/u/src/api", started: 1_700_000_000),
    row("c5", "claude", project: "/u/src/api", started: 1_700_003_600),
    row("c6", "claude", project: "/u/src/same"),
    row("c7", "claude", project: "/u/src/same"),
    row("u1", "cursor", host: "Cursor", ws: []),
    row("u2", "cursor", host: "Cursor", ws: ["/u/src/kai", "/u/src/web"]),
    row("x1", "codex"),
]
SessionRow.assignNames(&named, topic: { $0.topic })
let byId = Dictionary(uniqueKeysWithValues: named.map { ($0.id, $0.name) })
check(byId["c1"] == "kai · Terminal tab 1" && byId["c2"] == "kai · Terminal tab 2",
      "project folder plus terminal tab: \(byId["c1"]!), \(byId["c2"]!)")
check(byId["c3"] == "Fix the login page · Terminal tab 4", "the topic, when the agent reported one: \(byId["c3"]!)")
check(byId["c4"] != byId["c5"] && byId["c4"]!.hasPrefix("api · started "),
      "same project, no tab: told apart by start time: \(byId["c4"]!), \(byId["c5"]!)")
check(byId["c6"] != byId["c7"], "identical sessions still get different names: \(byId["c6"]!), \(byId["c7"]!)")
check(Set(named.map(\.name)).count == named.count, "no two names are the same")
check(!byId["u1"]!.contains("Cursor"), "a Cursor app with no workspace isn't called \"Cursor\": \(byId["u1"]!)")
check(byId["u2"] == "kai +1", "a Cursor app named by its workspaces: \(byId["u2"]!)")
check(!byId["x1"]!.isEmpty && !byId["x1"]!.contains("Codex"), "a session with nothing known still has a name: \(byId["x1"]!)")

print(fails == 0 ? "sessions tests: all passed" : "sessions tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
