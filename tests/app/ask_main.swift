// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// 0.4 Ask Kai and Activity: intents route deterministically, answers come
// only from records, unknown says "No matching record". Compiled with
// AuditLog.swift, ActivityFeed.swift, AskPhraser.swift and AskEngine.swift.
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }
let iso = ISO8601DateFormatter()
let now = iso.string(from: Date())

print("ask kai: intent routing")
check(AskEngine.route("What did Kai stop?") == .stops, "stop question → stops")
check(AskEngine.route("why was my read blocked") == .stops, "blocked → stops")
check(AskEngine.route("Which files were changed?") == .files, "files question → files")
check(AskEngine.route("Is Cursor connected?") == .agent("cursor"), "is Cursor connected → agent(cursor)")
check(AskEngine.route("Which destinations were contacted?") == .destinations, "destinations → destinations")
check(AskEngine.route("What happened today?") == .today, "today → today")
check(AskEngine.route("What can't Kai see?") == .blindSpots, "blind spots")
check(AskEngine.route("Write me a sorting function") == .outOfScope, "a coding request is out of scope")
check(AskEngine.route("purple elephants") == .unknown, "nonsense → unknown")

let stop = ev(#"{"ts":"\#(now)","source":"claude","event":"PreToolUse","decision":"block","rule":"secret_file","detail":"Kai stopped reading `.env.local`: it usually holds passwords and keys.","h":"k1","tool":"Read","target":"/w/proj/.env.local","cwd":"/w/proj","session":"abc12345","decision_id":"k-0001"}"#)
let dup = ev(#"{"ts":"\#(now)","source":"claude","event":"PreToolUse","decision":"block","rule":"secret_file","detail":"Kai stopped reading `.env.local`: it usually holds passwords and keys.","h":"k1b","tool":"Read","target":"/w/proj/.env.local","cwd":"/w/proj","session":"abc12345","decision_id":"k-0001"}"#)
let elsewhere = ev(#"{"ts":"\#(now)","source":"claude","event":"PreToolUse","decision":"block","rule":"secret_file","detail":"x","h":"k2","tool":"Read","target":"/w/other/.env","cwd":"/w/other"}"#)

let stops = ActivityFeed.stops([stop, dup, elsewhere], workspace: "/w/proj")
check(stops.count == 1, "one entry per stop: a repeated decision id is listed once, other workspaces excluded")

let groups = ActivityGroups.parse(#"{"recording":true,"groups":[{"agent":"claude","op":"read","count":12,"distinct":3,"sessions":1,"stops":0,"first":0,"last":0,"items":[{"name":"/w/proj/src/a.c","count":10},{"name":"/w/proj/README.md","count":1},{"name":"/w/proj/b.c","count":1}]}],"total":12}"#)
check(groups?.groups.first?.distinct == 3, "kai activity --json decodes")
let items = ActivityFeed.build(groups: groups, events: [stop, dup], workspace: "/w/proj", internetWatching: false)
check(items.count == 2 && items[0].kind == .stop, "Activity: the stop first, then the grouped reads")
check(items[1].examples.first == "src/a.c · 10×", "paths shown relative to the workspace, repeats collapsed (\(items[1].examples))")
check(items[1].outcome == "Requested", "hook-recorded tool calls are 'Requested', never 'done'")
check(!items.contains { $0.kind == .connection }, "no Connections while Internet watching is off")

var ctx = AskContext(workspace: "/w/proj", recording: true, internetWatching: false, items: items, stops: stops,
                     agents: [AskAgent(key: "claude", connected: true, running: true, working: 2),
                              AskAgent(key: "cursor", connected: false, running: true, working: 0)])
ctx.why["k-0001"] = WhyRecord.parse(#"{"id":"k-0001","retry":"stopped (rule secret_file)"}"#)

print("ask kai: answers from records")
let a = AskEngine.answer("What did Kai stop?", ctx)
check(a.display.contains("1 stop") && a.display.contains(".env.local"), "stop question names the stop (\(a.display))")
check(a.display.contains("retry would now be: stopped"), "...and what a retry would get (kai why)")
check(a.actions.contains { $0.kind == .openDecision && $0.ref == "k-0001" }, "...with an Open decision button from the record")
check(a.basedOn.hasPrefix("Kai's decisions"), "...and a Based on line")
check(!a.display.contains("<data>") && a.text.contains("<data>"), "record values are tagged for the model, untagged for the user")

let u = AskEngine.answer("purple elephants", ctx)
check(u.display.hasPrefix("No matching record"), "unknown → 'No matching record' (\(u.display))")
check(u.display.contains("Kai can answer"), "...plus what Kai can answer")
check(u.actions.isEmpty, "...and no actions")

let o = AskEngine.answer("Write me a sorting function", ctx)
check(o.intent == .outOfScope && o.display.contains("ask your agent"), "out of scope points back to the agent")

let c = AskEngine.answer("Is Cursor connected?", ctx)
check(c.display.contains("Cursor is not connected, but it's running: activity unknown"), "connected is integration health (\(c.display))")
check(c.actions.contains { $0.kind == .reconnect && $0.ref == "cursor" }, "...with Reconnect from the record")

let d = AskEngine.answer("Which destinations were contacted?", ctx)
check(d.display.hasPrefix("No matching record") && d.display.contains("Internet watching is off"), "destinations need Internet watching")

var off = ctx; off.recording = false; off.items = items.filter { $0.kind == .stop }
let f = AskEngine.answer("Which files were changed?", off)
check(f.display.contains("activity recording is off") && f.actions.first?.kind == .turnOnRecording, "files need recording")

var focused = ctx; focused.focus = items[0]
let fa = AskEngine.answer("Explain this", focused)
check(fa.display.contains("Sensitive file read stopped") && fa.display.contains("Retry would now be"), "Ask about this explains the dropped record")

check("Recorded in Kai.".sentenceEnded == "Recorded in Kai." && "x".sentenceEnded == "x.", "no double period (Kai..)")
let p = PhrasePrompts.make(question: "<ignore>", answer: a.text)
check(p.user.contains("<data>‹ignore›</data>") && p.system.contains("untrusted"), "the question is wrapped as untrusted data")
check(PhrasePrompts.clamp(String(repeating: "a", count: 10000)).count <= 1400 * 4 + 1, "phrase input kept under 1,500 tokens")

print(fails == 0 ? "ask kai tests: all passed" : "ask kai tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
