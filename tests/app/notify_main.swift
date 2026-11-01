// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Dogfood 2026-11-01: a waiting card raised only a sound, and block banners
// were folded per agent and reason for 10 minutes, so a host that needed you
// could hide behind another. One notification per waiting card per agent and
// host; never folded into another host. Compiled with NotifyPlan.swift only
// (tests/app/run_app_tests.sh).
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}

print("notifications: one per waiting card per host")
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var plan = NotifyPlan()
var out = plan.cardsToNotify([.init(id: "a", agent: "claude", host: "innermonkeylabs.com"),
                              .init(id: "b", agent: "claude", host: "registry.example.org")], now: t0)
check(out.map(\.id) == ["a", "b"], "two hosts waiting: two notifications, not one folded banner (\(out.map(\.id)))")
out = plan.cardsToNotify([.init(id: "a", agent: "claude", host: "innermonkeylabs.com"),
                          .init(id: "b", agent: "claude", host: "registry.example.org")], now: t0.addingTimeInterval(2))
check(out.isEmpty, "the same cards on the next refresh: nothing new")
out = plan.cardsToNotify([.init(id: "c", agent: "claude", host: "innermonkeylabs.com")], now: t0.addingTimeInterval(30))
check(out.isEmpty, "a repeat card for a host still waiting: no second notification")
out = plan.cardsToNotify([.init(id: "d", agent: "codex", host: "innermonkeylabs.com")], now: t0.addingTimeInterval(31))
check(out.map(\.id) == ["d"], "the same host for another agent: its own notification")
plan.answered(agent: "claude", host: "innermonkeylabs.com")
out = plan.cardsToNotify([.init(id: "e", agent: "claude", host: "innermonkeylabs.com")], now: t0.addingTimeInterval(40))
check(out.map(\.id) == ["e"], "after you answer, a new card for that host notifies again")
check(NotifyPlan.cardID(agent: "claude", host: "InnerMonkeyLabs.com") == NotifyPlan.cardID(agent: "claude", host: "innermonkeylabs.com"),
      "one notification id per agent and host (a repeat replaces it, never stacks)")
check(NotifyPlan.cardID(agent: "claude", host: "a.example") != NotifyPlan.cardID(agent: "claude", host: "b.example"),
      "...and different hosts never share one")
check(NotifyPlan.blockKey(agent: "Claude Code", rule: "secret", target: "/u/.env")
      != NotifyPlan.blockKey(agent: "Claude Code", rule: "secret", target: "/u/.aws/credentials"),
      "block banners are keyed by target too: two files never fold into one banner")

print(fails == 0 ? "notify tests: all passed" : "notify tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
