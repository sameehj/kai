// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Spec §4 regression: "Hosts your agents reached" grouped by the record's
// reason code (not_on_allowlist) instead of the destination. Compiled with
// AuditLog.swift and Reach.swift only (tests/app/run_app_tests.sh).
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }

let events = [
    ev(#"{"ts":"2026-10-29T08:00:00Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"connection to example.org (1.2.3.4:443) is not on the allowlist","h":"a1","target":"example.org"}"#),
    ev(#"{"ts":"2026-10-29T08:01:00Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"connection to example.org (1.2.3.4:443) is not on the allowlist","h":"a2","target":"example.org"}"#),
    ev(#"{"ts":"2026-10-29T08:02:00Z","source":"network","event":"cursor","decision":"log","rule":"not_on_allowlist","detail":"connection to developerservices2.apple.com (5.6.7.8:443) is not on the allowlist","h":"a3","target":"developerservices2.apple.com"}"#),
    ev(#"{"ts":"2026-10-29T08:03:00Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"telemetry to sentry.io (1.1.1.1:443); not asked about","h":"a4","target":"sentry.io"}"#),
    ev(#"{"ts":"2026-10-29T08:04:00Z","source":"network","event":"cursor","decision":"log","rule":"not_on_allowlist","detail":"QUIC (UDP 443) dropped so the agent uses HTTPS","h":"a5","target":"QUIC"}"#),
    ev(#"{"ts":"2026-10-29T08:05:00Z","source":"grant","event":"requested","decision":"request","rule":"connect","detail":"grant requested id=net-1 agent=claude","h":"a6","target":"example.org"}"#),
]

print("reached hosts (spec 4)")
let hosts = ReachedHost.group(events, allowed: [])
check(!hosts.contains { $0.host == "not_on_allowlist" }, "a rule name is never shown as a host")
check(hosts.map(\.host).sorted() == ["developerservices2.apple.com", "example.org"], "one row per destination")
check(hosts.first { $0.host == "example.org" }?.count == 2, "repeats are counted, not listed")
check(!hosts.contains { $0.host == "sentry.io" || $0.host == "QUIC" }, "telemetry and the QUIC fallback aren't listed")
check(ReachedHost.group(events, allowed: ["example.org"]).map(\.host) == ["developerservices2.apple.com"],
      "allowed destinations drop out")

print("plain sentences (spec 4, 8)")
let own = ev(#"{"ts":"2026-10-29T08:06:00Z","source":"claude","event":"PreToolUse","decision":"block","rule":"~/.kai","detail":"command touches protected path (~/.kai)","h":"b1","tool":"Bash","target":"cat ~/.kai/policy"}"#)
check(own.plainSentence == "Claude Code tried to read Kai's settings. Always protected.", "Kai's own files: \(own.plainSentence)")
let ssh = ev(#"{"ts":"2026-10-29T08:07:00Z","source":"claude","event":"PreToolUse","decision":"block","rule":"~/.ssh","detail":"Kai blocked reading `~/.ssh/id_ed25519`: private keys can unlock your servers.","h":"b2","tool":"Read","target":"~/.ssh/id_ed25519"}"#)
check(ssh.plainSentence == "Claude Code tried reading ~/.ssh/id_ed25519. Blocked.", "a protected file: \(ssh.plainSentence)")
check(!events[0].plainSentence.contains("..") && !events[0].plainSentence.contains("not_on"), "no double period, no rule names")

print(fails == 0 ? "app tests: all passed" : "app tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
