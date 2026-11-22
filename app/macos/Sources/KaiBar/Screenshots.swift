// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// `make screenshots` (0.5.1): the README's pictures, rendered from the real
// SwiftUI views with a FIXTURE data set, never the owner's live data. A Debug
// build only:
//
//   Kai.app/Contents/MacOS/Kai --kai-screenshots <dir> [--internet watch|blocklist]
//
// In this mode every store starts empty and inert (no CLI runs, no timers, no
// lock, no writes, no auto-connect): AppModel, AgentsModel, KaiRecords,
// NetworkWall, GrantManager and the model chooser return at once from their
// refresh paths (ScreenshotFixture.active). The fixture is loaded, each view
// is drawn offscreen at @2x in light and dark, and the app quits.
//
// Fixture rules: neutral project names (acme-web, api-server, docs-site),
// paths under ~/code, program names only (never a command line), and
// scripts/screenshots.sh runs this with a time zone that puts "now" at
// 10:40, so every clock reads between 09:00 and 11:00.
#if DEBUG
import AppKit
import SwiftUI

enum ScreenshotFixture {
    static var active: Bool { CommandLine.arguments.contains("--kai-screenshots") }
    static var outDir: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--kai-screenshots"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var internetMode: InternetMode {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--internet"), i + 1 < a.count else { return .blocklist }
        return a[i + 1] == "watch" ? .watch : .blocklist
    }
}

@MainActor
enum ScreenshotRenderer {
    static let home = NSHomeDirectory() + "/code"
    static var now: Int { Int(Date().timeIntervalSince1970) }

    static func run(to dir: String) async {
        // A time zone whose local time is 10:40 now: every clock in the
        // pictures reads between 09:00 and 11:00.
        let utcMin = (Int(Date().timeIntervalSince1970) / 60) % 1440
        var off = (640 - utcMin + 1440) % 1440
        if off > 720 { off -= 1440 }
        if let tz = TimeZone(secondsFromGMT: off * 60) { NSTimeZone.default = tz }
        let model = AppModel(), wall = NetworkWall(), storage = StorageWall()
        let mode = ScreenshotFixture.internetMode
        load(model: model, wall: wall, mode: mode)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func render<V: View>(_ v: V, width: CGFloat, height: CGFloat?, name: String) {
            for dark in [false, true] {
                let root = v.environmentObject(model).environmentObject(wall).environmentObject(storage)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Theme.ink)
                let host = NSHostingView(rootView: AnyView(root.frame(width: width)))
                let size = NSSize(width: width, height: height ?? max(120, host.fittingSize.height))
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                // @2x, whatever screen this runs on.
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                 pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir + "/" + name + (dark ? "-dark" : "") + ".png"))
                }
                win.contentView = nil
            }
        }

        let nav = MainNav.shared
        nav.chatHidden = true
        nav.page = .now
        render(MainWindowView(), width: 1080, height: 700, name: "now")
        nav.page = .activity
        nav.filter = .all; nav.agentFilter = nil; nav.sessionFilter = nil; nav.projectFilter = nil; nav.search = ""
        render(MainWindowView(), width: 1080, height: 700, name: "activity")
        nav.page = .ask
        nav.chatHidden = false
        render(MainWindowView(), width: 1080, height: 700, name: "ask")
        nav.chatHidden = true
        render(MenuView().fixedSize(horizontal: false, vertical: true), width: 320, height: nil, name: "popover")
        UserDefaults.standard.set(SettingsPage.internet.rawValue, forKey: "settingsPage")
        render(SettingsView(), width: 1080, height: mode == .blocklist ? 900 : 760, name: "internet")
        if let stop = model.events.first(where: { $0.id == "fx-stop-env" }) {
            render(DecisionDetailSheet(event: stop, workspace: home + "/acme-web").background(Theme.surface),
                   width: 560, height: nil, name: "stop-detail")
        }
        exit(0)
    }

    // MARK: the fixture

    static func load(model: AppModel, wall: NetworkWall, mode: InternetMode) {
        let t = now
        let acme = home + "/acme-web", api = home + "/api-server", docs = home + "/docs-site"
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase

        let sessions = (try? SessionSnapshot.decode(Data("""
        {"sessions":[
         {"id":"fx-acme","agent":"claude","project":"\(acme)","tty":"ttys002","started_utc":\(t - 5280),"last_active_utc":\(t - 8),"activity":"working","kind":"session","state":"active","activity_keys":["fx-k-acme"]},
         {"id":"fx-api","agent":"claude","project":"\(api)","tty":"ttys004","started_utc":\(t - 2700),"last_active_utc":\(t - 40),"activity":"working","kind":"session","state":"active","activity_keys":["fx-k-api"]},
         {"id":"fx-api-mcp","agent":"claude","project":"\(api)","started_utc":\(t - 2650),"last_active_utc":\(t - 40),"activity":"working","kind":"background service","state":"active","activity_keys":["fx-k-api-mcp"]},
         {"id":"fx-cursor","agent":"cursor","host_app":"Cursor","started_utc":\(t - 4800),"last_active_utc":\(t - 1080),"activity":"idle","kind":"session","state":"active","workspaces":[{"path":"\(docs)","last_active_utc":\(t - 1080),"activity":"idle"}],"activity_keys":["fx-k-cursor"]}
        ],"agents":[]}
        """.utf8)).sessions) ?? []
        var agents: [AgentRow] = []
        for n in ["claude", "cursor", "codex"] {
            var r = AgentRow(name: n); r.detected = true; r.hooks = "installed"; agents.append(r)
        }
        AgentsModel.shared.loadFixture(agents: agents, sessions: sessions)

        let groups = ActivityGroups.parse("""
        {"recording":true,"groups":[
          {"agent":"claude","op":"read","count":27,"distinct":14,"sessions":2,"stops":1,"first":\(t - 5200),"last":\(t - 30),"items":[]},
          {"agent":"claude","op":"edit","count":9,"distinct":5,"sessions":2,"stops":0,"first":\(t - 5000),"last":\(t - 8),"items":[]},
          {"agent":"claude","op":"command","count":64,"distinct":6,"sessions":2,"stops":0,"first":\(t - 5100),"last":\(t - 40),"items":[]},
          {"agent":"cursor","op":"read","count":11,"distinct":7,"sessions":1,"stops":0,"first":\(t - 4700),"last":\(t - 1080),"items":[]}
        ],"total":111,"today":111,"first_record":\(t - 5200),"sessions":[
         {"key":"fx-k-acme","agent":"claude","workspace":"\(acme)","first":\(t - 5200),"last":\(t - 8),
          "counts":{"read":18,"edit":6,"write":1,"command":23,"mcp":0,"tool":0},"stops":1,
          "events":[{"ts":\(t - 8),"op":"edit","name":"\(acme)/src/components/Pricing.tsx","decision":"allow"},
                    {"ts":\(t - 95),"op":"command","name":"npm","decision":"allow"},
                    {"ts":\(t - 160),"op":"read","name":"\(acme)/src/lib/plans.ts","decision":"allow"},
                    {"ts":\(t - 300),"op":"write","name":"/private/tmp/acme-build/report.txt","decision":"allow"},
                    {"ts":\(t - 310),"op":"write","name":"/private/tmp/acme-build/coverage.json","decision":"allow"},
                    {"ts":\(t - 330),"op":"read","name":"/private/tmp/acme-build/out.log","decision":"allow"},
                    {"ts":\(t - 1680),"op":"read","name":"\(acme)/.env","decision":"block"},
                    {"ts":\(t - 1700),"op":"read","name":"\(acme)/package.json","decision":"allow"},
                    {"ts":\(t - 1800),"op":"command","name":"git","decision":"allow"}]},
         {"key":"fx-k-api","agent":"claude","workspace":"\(api)","first":\(t - 2600),"last":\(t - 40),
          "counts":{"read":9,"edit":3,"write":0,"command":41,"mcp":0,"tool":0},"stops":0,
          "events":[{"ts":\(t - 40),"op":"command","name":"pytest","decision":"allow"},
                    {"ts":\(t - 220),"op":"edit","name":"\(api)/app/routes/billing.py","decision":"allow"},
                    {"ts":\(t - 400),"op":"read","name":"\(api)/app/models.py","decision":"allow"}]},
         {"key":"fx-k-cursor","agent":"cursor","workspace":"\(docs)","first":\(t - 4700),"last":\(t - 1080),
          "counts":{"read":11,"edit":0,"write":0,"command":2,"mcp":0,"tool":0},"stops":1,
          "events":[{"ts":\(t - 1080),"op":"read","name":"\(docs)/docs/getting-started.md","decision":"allow"},
                    {"ts":\(t - 1500),"op":"read","name":"\(docs)/.env.local","decision":"block"}]}
        ]}
        """)
        let why = (try? JSONDecoder().decode(WhyRecord.self, from: Data("""
        {"id":"d-7f3a91","component":"agent hook","rule":"protect .env","attribution":"hook: Claude Code session in acme-web",
         "recovery":"Allow this one read for this session, or keep it blocked.","retry":"stopped (rule protect .env)"}
        """.utf8)))
        KaiRecords.shared.loadFixture(groups: groups, why: why.map { ["d-7f3a91": $0] } ?? [:])

        let iso = ISO8601DateFormatter()
        func ts(_ ago: Int) -> String { iso.string(from: Date(timeIntervalSince1970: TimeInterval(t - ago))) }
        let eventsJSON = """
        [{"ts":"\(ts(1680))","source":"claude","event":"PreToolUse","decision":"block","rule":"protect","detail":"Kai stopped reading .env: the file can hold secrets, and your policy protects .env files","h":"fx-stop-env","tool":"Read","target":"\(acme)/.env","session":"fx-k-acme","cwd":"\(acme)","decision_id":"d-7f3a91"},
         {"ts":"\(ts(1500))","source":"cursor","event":"beforeReadFile","decision":"block","rule":"protect","detail":"Kai stopped reading .env.local: your policy protects .env files","h":"fx-stop-cursor","tool":"Read","target":"\(docs)/.env.local","cwd":"\(docs)","decision_id":"d-41c2e0"},
         {"ts":"\(ts(900))","source":"network","event":"claude","decision":"log","rule":"not_on_allowlist","detail":"connection to registry.npmjs.org (104.16.0.35:443) is not on the allowlist","h":"fx-net-1","target":"registry.npmjs.org"},
         {"ts":"\(ts(600))","source":"network","event":"claude","decision":"log","rule":"not_on_allowlist","detail":"connection to api.github.com (140.82.112.6:443) is not on the allowlist","h":"fx-net-2","target":"api.github.com"}]
        """
        let events = ((try? JSONDecoder().decode([AuditEvent].self, from: Data(eventsJSON.utf8))) ?? [])
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let status = try? dec.decode(KaiStatus.self, from: Data("""
        {"version":"0.5.1-preview.1","commit":"fixture","exe":"/usr/local/bin/kai","home":"~/.kai",
         "install":{"launcher":true,"root_only":true},
         "policy":{"ok":true,"source":"file","file":"~/.kai/policy","file_exists":true,"error":""},
         "claude":{"installed":true,"detected":true,"config":"~/.claude/settings.json","working":true,"last_hook":\(t - 8)},
         "cursor":{"installed":true,"detected":true,"config":"~/.cursor/hooks.json","working":true,"last_hook":\(t - 1080)},
         "codex":{"installed":true,"detected":true,"config":"~/.codex/hooks.json","working":true,"last_hook":\(t - 86400 * 2)},
         "audit":{"path":"~/.kai/audit.log","records":412,"intact":true,"error":""},
         "walls":{"configured":{"storage":"off","network":"\(mode.egress)"},"observed":{"network":{"running":true}}}}
        """.utf8))
        let policy = try? dec.decode(PolicyInfo.self, from: Data("""
        {"file":"~/.kai/policy","exists":true,"ok":true,"error":"",
         "switches":{"record_activity":"on","egress":"\(mode.egress)","secrets":"redact","on_file_secret":"ask"},
         "protect":["~/.ssh",".env"],"allow":[".env.example"],"egress_allow":[],"egress_block":[],
         "channels":[],"terms":[],"rules":[],"exempt":[]}
        """.utf8))
        model.loadFixture(status: status, policy: policy, events: events)
        wall.loadFixture(.on)
        InternetMode.current = mode
        BlockList.shared.loadFixture(mode == .blocklist ? [
            .init(value: "pastebin.com", agent: "*", fromPolicy: false),
            .init(value: "transfer.sh", agent: "*", fromPolicy: false),
            .init(value: "statsig.com", agent: "*", fromPolicy: false),
        ] : [])
        ModelController.shared.loadFixture(.active(.local))

        // Ask: two questions, answered by Kai's own engine from this fixture.
        let ctx = MainWindowView.context(model: model, wall: wall, agents: AgentsModel.shared, records: KaiRecords.shared,
                                         nav: MainNav.shared)
        var thread = ChatThread(workspace: nil, title: "What did Claude Code do in acme-web today?")
        for q in ["What did Claude Code do in acme-web today?", "Why was the .env read stopped?"] {
            let a = AskEngine.answer(q, ctx, intent: AskEngine.route(q))
            thread.messages.append(ChatMessage(role: .user, text: q))
            thread.messages.append(ChatMessage(role: .kai, text: a.display, basedOn: a.basedOn, actions: a.actions,
                                               limits: a.limits.isEmpty ? nil : a.limits.map(AskAnswer.untag)))
        }
        AskController.shared.loadFixture([thread])
    }
}
#endif
