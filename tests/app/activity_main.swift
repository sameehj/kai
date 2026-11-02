// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Nov 1 corrective change, step 5: permission screens tell one story. Compiled
// with AuditLog.swift and ActivityRules.swift only (tests/app/run_app_tests.sh).
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }

print("activity: icons, words, merges")
let approved1 = ev(#"{"ts":"2026-11-01T19:28:45Z","source":"grant","event":"approved","decision":"sign","rule":"connect","detail":"grant approved id=05086482 agent=claude approved by console user","h":"g1","target":"innermonkeylabs.com"}"#)
let approved2 = ev(#"{"ts":"2026-11-01T19:47:18Z","source":"grant","event":"approved","decision":"sign","rule":"connect","detail":"grant approved id=act-b6926 agent=claude rule created with owner authentication","h":"g2","target":"innermonkeylabs.com"}"#)
let used = ev(#"{"ts":"2026-11-01T19:30:01Z","source":"grant","event":"used","decision":"allow","rule":"connect","detail":"grant used id=32FED2D9 agent=claude your rule","h":"g3","target":"innermonkeylabs.com"}"#)
let netBlock = ev(#"{"ts":"2026-11-01T19:28:38Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"connection to innermonkeylabs.com (1.2.3.4:443) is not on the allowlist","h":"n1","target":"innermonkeylabs.com"}"#)
let otherBlock = ev(#"{"ts":"2026-11-01T19:29:00Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"connection to other.example (1.2.3.4:443) is not on the allowlist","h":"n2","target":"other.example"}"#)
let observed = ev(#"{"ts":"2026-11-02T08:00:00Z","source":"network","event":"claude","decision":"log","rule":"not_on_allowlist","detail":"connection to example.org (1.2.3.4:443) is not on the allowlist","h":"n3","target":"example.org"}"#)
let hookBlock = ev(#"{"ts":"2026-11-02T08:00:00Z","source":"claude","event":"PreToolUse","decision":"block","rule":"secret_file","detail":"Kai stopped a command that uses .env","h":"k1","tool":"Bash","target":"cat .env"}"#)
let readBlock = ev(#"{"ts":"2026-11-02T08:00:00Z","source":"claude","event":"PreToolUse","decision":"block","rule":"protected_path","detail":"Kai stopped reading ~/.ssh/id_ed25519","h":"k2","tool":"Read","target":"/Users/u/.ssh/id_ed25519"}"#)
let note = ev(#"{"ts":"2026-11-02T08:00:00Z","source":"claude","event":"mcp-server","decision":"note","rule":"mcp_unpinned","detail":"MCP server wp runs from an unpinned npx spec","h":"k3","target":"wp"}"#)

check(approved1.tone == .allowed && used.tone == .allowed, "allowed rows are 'allowed' (green), never a warning")
check(approved1.iconName != "exclamationmark.triangle.fill" && used.iconName != "exclamationmark.triangle.fill",
      "...and never the ⚠ icon (\(approved1.iconName))")
check(note.tone == .neutral && note.verb == "Note", "a note is neutral and says Note, not Warning (\(note.verb))")
check(hookBlock.verb == "Denied by agent check", "a hook stop says 'Denied by agent check' (\(hookBlock.verb))")
check(observed.verb == "Observed" && observed.tone == .neutral, "network activity in Watch says 'Observed' (\(observed.verb))")
check(hookBlock.whileRunning == "cat .env", "'While running:' is the triggering command for a shell tool")
check(readBlock.whileRunning == nil, "...omitted for a file read (a path isn't a command)")
check(netBlock.whileRunning == nil, "...omitted for a connection (the command isn't known)")
check(approved1.mergeKey == approved2.mergeKey, "one grant record per agent and target: two approvals merge")
check(approved1.mergeKey != used.mergeKey, "...an approval and a use stay separate kinds")

let recent = AuditEvent.droppingAllowedBlocks([used, otherBlock, netBlock])   // newest first
check(!recent.contains(where: { $0.h == "n1" }), "Recent drops a 'Blocked' row once that host is allowed")
check(recent.contains(where: { $0.h == "n2" }), "...and keeps blocks of hosts still not allowed")

print("activity: scope and duration agree")
let now = 1_800_000_000
check(GrantText.scope(scope: 2, session: true, created: now, expires: now + 604_800) == "this session",
      "a session grant says 'this session', no clock time")
check(GrantText.status(session: true, expires: now + 604_800, now: now) == "until the session ends",
      "...and its status never shows hours left")
check(GrantText.scope(scope: 2, session: false, created: now, expires: now + 604_800) == "for 7 days",
      "a timed grant says 'for 7 days'")
check(GrantText.scope(scope: 2, session: false, created: now, expires: now + 3600) == "for 1 hour", "...'for 1 hour'")
check(!GrantText.scope(scope: 2, session: false, created: now, expires: now + 86_400).contains("process"),
      "never 'this process'")
check(GrantText.scope(scope: 1, session: false, created: now, expires: now + 600) == "once", "a one-shot grant says 'once'")

print(fails == 0 ? "activity tests: all passed" : "activity tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
