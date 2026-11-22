// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// 0.5: Now (cards, grouping, nested sessions, "not reported" fields, the
// shared count behind the Now header and the toolbar pill), the Activity
// timeline, the model chip's state machine, the icon resolver's fallback,
// Kai's deterministic answer footer, and old deep links' redirects.
// Compiled with the Foundation-only app files (run_app_tests.sh).
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func snap(_ json: String) -> [SessionRow] { try! SessionSnapshot.decode(Data(json.utf8)).sessions }
func acts(_ json: String) -> ActivityGroups { ActivityGroups.parse(json)! }
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }

let t = Int(Date().timeIntervalSince1970)
let sessions = snap("""
{"sessions":[
 {"id":"scan-100","agent":"claude","project":"/w/acme-web","tty":"ttys002","started_utc":\(t - 2220),"last_active_utc":\(t - 10),"activity":"working","kind":"session","state":"active","activity_keys":["pid-100"]},
 {"id":"scan-200","agent":"claude","project":"/w/api-server","tty":"ttys000","started_utc":\(t - 1500),"last_active_utc":\(t - 30),"activity":"working","kind":"session","state":"active","activity_keys":["pid-200"]},
 {"id":"scan-201","agent":"claude","project":"/w/api-server","tty":"","started_utc":\(t - 1400),"last_active_utc":\(t - 30),"activity":"working","kind":"nested","state":"active","activity_keys":["pid-201"]},
 {"id":"scan-300","agent":"cursor","host_app":"Cursor","started_utc":\(t - 4000),"last_active_utc":\(t - 720),"activity":"idle","kind":"session","state":"active","workspaces":[{"path":"/w/docs-site","last_active_utc":\(t - 720),"activity":"idle"}],"activity_keys":["pid-300"]},
 {"id":"scan-400","agent":"codex","project":"/w/api-server","started_utc":\(t - 900),"last_active_utc":\(t - 900),"activity":"idle","kind":"background service","state":"active","activity_keys":["pid-400"]},
 {"id":"es-9","agent":"claude","project":"/w/acme-web","started_utc":\(t - 9000),"ended_utc":\(t - 8000),"activity":"ended","kind":"session","state":"ended"}
],"agents":[]}
""")
let records = acts("""
{"recording":true,"groups":[],"total":0,"first_record":\(t - 3000),"sessions":[
 {"key":"pid-100","agent":"claude","workspace":"/w/acme-web","first":\(t - 2000),"last":\(t - 5),
  "counts":{"read":12,"edit":4,"write":1,"command":9,"mcp":0,"tool":0},"stops":1,
  "events":[{"ts":\(t - 5),"op":"edit","name":"/w/acme-web/src/Pricing.tsx","decision":"allow"},
            {"ts":\(t - 120),"op":"read","name":"/w/acme-web/.env","decision":"block"},
            {"ts":\(t - 200),"op":"command","name":"npm","decision":"allow"}]},
 {"key":"pid-300","agent":"cursor","workspace":"/w/docs-site","first":\(t - 3000),"last":\(t - 720),
  "counts":{"read":4,"edit":0,"write":0,"command":2,"mcp":0,"tool":0},"stops":0,
  "events":[{"ts":\(t - 720),"op":"read","name":"/w/docs-site/package.json","decision":"allow"}]},
 {"key":"conv-old","agent":"claude","workspace":"/w/acme-web/src","first":\(t - 1800),"last":\(t - 1700),
  "counts":{"read":1,"edit":0,"write":0,"command":0,"mcp":0,"tool":0},"stops":0,"events":[]}
]}
""")
check(sessions.first?.activityKeys == ["pid-100"], "kai snapshot's activity_keys decode")
check(records.sessions?.count == 3 && records.first_record == Double(t - 3000), "kai activity's sessions and first_record decode")

print("now: one card per session, grouped by agent")
let secs = NowBuilder.sections(sessions: sessions, records: records.sessions ?? [], events: [])
check(secs.map(\.agent) == ["claude", "cursor"], "sections in agent order; a background service alone makes no card (\(secs.map(\.agent)))")
let claude = secs[0]
check(claude.cards.count == 2, "two Claude Code sessions are two cards, not one per agent")
check(claude.line == "Claude Code · 2 working", "section line (\(claude.line))")
let api = claude.cards.first { $0.project == "api-server" }!
check(api.children.map(\.id) == ["scan-201"], "the nested session sits under its parent")
check(!secs.flatMap(\.cards).contains { $0.id == "scan-201" || $0.id == "scan-400" }, "nested and background rows are never cards")
check(!secs.flatMap(\.cards).contains { $0.id == "es-9" }, "an ended session isn't a live card")
check(NowBuilder.endedToday(sessions, now: Date()).map(\.id) == ["es-9"], "ended today collapses into Earlier today")

print("now: last action, counts, not reported")
let acme = claude.cards.first { $0.project == "acme-web" }!
check(acme.lastLine(now: Date()) == "Editing Pricing.tsx · now", "live line: file name only (\(acme.lastLine(now: Date()) ?? "nil"))")
check(acme.activity?.counts.read == 13, "pre-0.5 records in the same project join the only session there")
check(acme.counts.first { $0.kind == .edits }?.value == 5, "edits count edits and writes")
let cursor = secs[1].cards[0]
check(cursor.statePill(now: Date()) == "Idle 12 min", "idle pill (\(cursor.statePill(now: Date())))")
check(cursor.lastLine(now: Date()) == "Read package.json · 12 min ago", "past tense with age (\(cursor.lastLine(now: Date()) ?? ""))")
let ce = cursor.counts.first { $0.kind == .edits }!
check(ce.value == nil && ce.text == "edits: not reported by Cursor", "Cursor edits: not reported, never 0 (\(ce.text))")
var codexCard = NowCard(session: sessions[4])
codexCard.session.kind = "session"
check(codexCard.counts.filter { $0.notReportedBy == "Codex" }.map(\.kind) == [.reads, .edits], "Codex files: not reported")
check(AgentReports.footnote("codex") == "files: not reported by Codex" && AgentReports.footnote("claude") == nil,
      "a footer note only where something isn't reported")
let cmd = SessionActivity.Event(ts: Date().timeIntervalSince1970 - 300, op: "command", name: "npm", decision: "allow")
check(LastAction.line(cmd, now: Date()) == "Ran npm · 5 min ago", "a command shows only its program name")
let stopped = SessionActivity.Event(ts: Date().timeIntervalSince1970, op: "read", name: "/w/x/.env", decision: "block")
check(LastAction.line(stopped, now: Date()) == "Kai stopped a read of .env · now", "a stopped read (0.5.1: Kai is the subject)")
check(ActivityFeed.program("API_TOKEN=x /usr/bin/npm test --secret") == "npm", "stop rows: program name only, no VAR= or arguments")

print("now: one count for the Now header, the toolbar pill and the popover")
let sum = NowSummary.of(secs)
check(sum.text == "2 working · 1 idle", "summary (\(sum.text))")
check(sum.working == secs.flatMap(\.cards).filter(\.working).count
      && sum.idle == secs.flatMap(\.cards).count - sum.working, "summary agrees with the cards")
check(sum.working + sum.idle == secs.reduce(0) { $0 + $1.cards.count }, "header and pill read the same source")
check(NowSummary.of([]).text == "No session running", "nothing running")
check(NowBuilder.emptyText(connected: ["claude", "codex"]) == "No agent is working right now. Kai is connected to Claude Code and Codex.",
      "empty state names only connected agents")

print("activity: one timeline grouped by session")
let groups = Timeline.groups(records: records.sessions ?? [], sessions: sessions, events: [], internetWatching: false)
let g1 = groups.first { $0.sessionID == "scan-100" }
check(g1 != nil && g1!.events.first?.title == "Edited Pricing.tsx", "group per session, newest first")
check(g1?.header(now: Date()).hasPrefix("Claude Code · acme-web · ") == true && g1?.header(now: Date()).hasSuffix("–now") == true,
      "group header (\(g1?.header(now: Date()) ?? ""))")
check(g1?.events.contains { $0.kind == .stop && $0.outcome == "Stopped" } == true, "a blocked request is a stop")
check(g1?.events.contains { $0.title == "Ran npm" && $0.outcome == "Agent asked to run" && $0.evidenceLevel.hasPrefix("Requested") } == true,
      "commands: program name, plain label, evidence level Requested")
check(Timeline.empty(projectFilter: "/w/docs-site", working: AgentsLike.working(sessions), recording: true, anyEvents: true)
      == .elsewhere(agent: "Claude Code", project: "acme-web", filter: "docs-site"), "a filter that hides a working session says where it is")
check(Timeline.empty(projectFilter: nil, working: [], recording: false, anyEvents: false) == .recordingOff, "recording off says so")
check(Timeline.empty(projectFilter: nil, working: [], recording: true, anyEvents: false) == .nothing, "truly nothing")
check(Timeline.recordingLate(firstRecord: Double(t - 3000), sessions: sessions)?.hasPrefix("Recording started at ") == true,
      "recording started after a live session began")

print("model chip: none → downloading → verified → active; delete → templates")
var st = ModelChip.State.none
check(ModelChip.label(st) == "Templates ▾", "templates label")
st = ModelChip.reduce(st, .startDownload, localInstalled: false, appleAvailable: false)
st = ModelChip.reduce(st, .progress(0.34), localInstalled: false, appleAvailable: false)
check(st == .downloading(0.34) && ModelChip.label(st) == "Qwen 34%", "progress on the chip (\(ModelChip.label(st)))")
check(ModelChip.reduce(st, .startDownload, localInstalled: false, appleAvailable: false) == st, "one download at a time")
check(ModelChip.reduce(st, .choose(.templates), localInstalled: false, appleAvailable: false) == st, "no switching mid-download")
st = ModelChip.reduce(st, .verified, localInstalled: true, appleAvailable: false)
check(st == .verified, "verified")
st = ModelChip.settle(st)
check(st == .active(.local) && ModelChip.label(st) == "Qwen 0.8B ▾", "switches to the model by itself")
st = ModelChip.reduce(st, .delete, localInstalled: false, appleAvailable: false)
check(st == .none, "delete returns to templates")
check(ModelChip.reduce(.downloading(0.5), .failed("x"), localInstalled: false, appleAvailable: false) == .failed("x"), "a failed download")
check(ModelChip.reduce(.none, .choose(.local), localInstalled: false, appleAvailable: false) == .none, "can't use a model that isn't downloaded")
check(ModelChip.reduce(.none, .choose(.appleIntelligence), localInstalled: false, appleAvailable: false) == .none,
      "Apple Intelligence only when available")
check(ModelChip.label(.active(.appleIntelligence)) == "Apple Intelligence ▾", "Apple Intelligence label")
let opts = ModelChip.options(.none, localInstalled: false, appleAvailable: false, appleReason: "Unavailable: needs macOS 26")
check(opts.count == 3 && opts[0].status.hasPrefix("Unavailable") && !opts[0].available, "unavailable shows its reason")
check(opts[1].size == "≈500 MB" && opts[1].status == "Not downloaded", "local model: size and status")
check(ModelChip.consentLine.contains("SHA-256") && ModelChip.consentLine.contains("Nothing you ask is sent anywhere"),
      "the consent line")

print("icon resolver")
check(AgentIconSource.resolve("cursor", installed: { _ in nil }) == .bundled("AgentCursor"), "no app installed: bundled Cursor mark")
check(AgentIconSource.resolve("codex", installed: { _ in nil }) == .bundled("AgentOpenAI"), "Codex falls back to the OpenAI mark")
check(AgentIconSource.resolve("claude", installed: { _ in nil }) == .bundled("AgentClaude"), "Claude falls back to the Claude mark")
let chat = URL(fileURLWithPath: "/Applications/ChatGPT.app")
check(AgentIconSource.resolve("codex", installed: { $0 == "com.openai.chat" ? chat : nil }) == .app(chat),
      "Codex uses the ChatGPT app when the Codex app isn't installed")
let cur = URL(fileURLWithPath: "/Applications/Cursor.app")
check(AgentIconSource.resolve("cursor", installed: { $0 == "com.todesktop.230313mzl4w4u92" ? cur : nil }) == .app(cur),
      "the installed app's icon wins")

print("ask: Kai's footer, outside the model's text")
var ctx = AskContext(workspace: nil, recording: true, internetWatching: false, items: [], stops: [],
                     agents: [AskAgent(key: "cursor", connected: true, running: true, working: 0)])
let a = AskEngine.answer("which files did cursor read", ctx)
check(!a.text.contains("editor's writes"), "the limit isn't in the text a model rewords")
check(a.footer.contains("Cursor doesn't report its editor's writes.") && a.footer.last?.hasPrefix("Based on: ") == true,
      "the limit and Based on are in Kai's footer (\(a.footer))")
// a model's rewording that drops the limitation: the message still carries it
var msgLimits = a.limits
let phrased = "Cursor read nothing today."
check(!phrased.contains("editor") && msgLimits.contains("Cursor doesn't report its editor's writes."),
      "a phrased answer that omits a limitation still renders it in the footer")
msgLimits.removeAll()
let ag = AskEngine.answer("is cursor connected", ctx)
check(ag.footer.contains("Edits: not reported by Cursor.") && !ag.text.contains("integration only"), "agent answer: limits in the footer")
ctx.session = NowCard(session: sessions[0], activity: (records.sessions ?? [])[0]).focus(now: Date(), recording: true)
let about = AskEngine.answer("Explain this", ctx)
check(about.display.hasPrefix("Claude Code in acme-web (Terminal tab 3): working") && about.display.contains("12 reads"),
      "Ask about this session (\(about.display))")
check(AskEngine.route("Which agents are working right now?") == .agent(""), "suggestion: which agents are working")
check(AskEngine.route("What did agents change today?") == .files, "suggestion: what changed")
check(AskEngine.route("Why did Kai stop something?") == .stops, "suggestion: why stopped")

print("deep links: old pages redirect")
check(KaiRoute.from(URL(string: "kai://settings/decisions")!) == .settings(.rules), "kai://settings/decisions → Settings → Rules")
check(KaiRoute.from(URL(string: "kai://settings/agents")!) == .settings(.agents), "kai://settings/agents → Settings → Agents")
check(KaiRoute.from(URL(string: "kai://decisions")!) == .activity(stopsOnly: true), "kai://decisions → Activity → Stops")
check(KaiRoute.from(URL(string: "kai://agents")!) == .settings(.agents), "kai://agents → Settings → Agents")
check(KaiRoute.from(URL(string: "kai://settings/network")!) == .settings(.internet), "0.3's network link still works")
check(KaiRoute.from(URL(string: "kai://settings/internet")!) == .settings(.internet), "kai://settings/internet")
check(KaiRoute.from(URL(string: "kai://now")!) == .now, "kai://now")
check(KaiRoute.from(URL(string: "https://example.com")!) == nil, "other schemes ignored")
check(SettingsPage(stored: "advanced") == .advanced && SettingsPage(stored: "bogus") == .general, "stored pages")
check(KaiRoute.fromSavedPage("agents") == .settings(.agents) && KaiRoute.fromSavedPage("decisions") == .activity(stopsOnly: true),
      "a 0.4 saved window page redirects")

print(fails == 0 ? "now tests: all passed" : "now tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)

enum AgentsLike {
    static func working(_ s: [SessionRow]) -> [SessionRow] { s.filter { $0.isSession && $0.isWorking } }
}
