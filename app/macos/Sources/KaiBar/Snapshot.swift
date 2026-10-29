// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// `Kai.app/Contents/MacOS/Kai --snapshot <dir>`: render the popover, Agent
// Control and Activity with live data into PNGs, then quit. For reviews and
// release checks, where nobody can click the menu-bar icon. Read-only: no
// lock, no writes beyond what one refresh does; popovers inside views aren't
// drawn.
import AppKit
import SwiftUI

enum Snapshot {
    static var requestedDir: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    @MainActor
    static func run(to dir: String) async {
        let model = AppModel(), wall = NetworkWall(), storage = StorageWall()
        await model.refresh()
        wall.refresh()
        await AgentsModel.shared.refresh()
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // walls and grants settle
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func render<V: View>(_ v: V, width: CGFloat, height: CGFloat?, name: String) {
            let root = v.environmentObject(model).environmentObject(wall).environmentObject(storage)
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: AnyView(root.frame(width: width)))
            let size = NSSize(width: width, height: height ?? max(200, host.fittingSize.height))
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
            }
        }

        render(MenuView(), width: 360, height: nil, name: "popover")
        // The decision cards at the popover's width with the longest agent and
        // host names (fixtures: live data rarely has a card waiting).
        let longHost = "artifacts-eu-west-1.internal-registry.example-enterprise.com"
        let dec = JSONDecoder()
        if let req = try? dec.decode(PendingRequest.self, from: Data(#"{"id":"fx","agent":"claude","pid":1,"pidversion":1,"strength":2,"resource":"\#(longHost)","op":"connect","ts":0,"session":"fx-session","project":"/Users/me/projects/kai","identity":"Developer ID Application: Anthropic PBC","hostKnown":true}"#.utf8)),
           let ev = try? dec.decode(AuditEvent.self, from: Data(#"{"ts":"2026-10-29T08:00:00Z","source":"network","event":"claude","decision":"block","rule":"not_on_allowlist","detail":"connection to \#(longHost) is not on the allowlist","h":"fx1","target":"\#(longHost)","identity":"Developer ID Application: Anthropic PBC"}"#.utf8)) {
            let grants = GrantManager()
            render(VStack(alignment: .leading, spacing: 12) {
                       ApprovalCard(req: req, count: 3, manager: grants)
                       DecisionSheet(event: ev, count: 2, grants: grants)
                   }.padding(16).background(Theme.ink),
                   width: 360, height: nil, name: "popover-cards")
        }
        render(AgentReachView(agent: "claude", grants: GrantManager()).background(Theme.ink),
               width: 640, height: 900, name: "agent-claude-page")
        let saved = UserDefaults.standard.string(forKey: "settingsPage")
        UserDefaults.standard.set(SettingsPage.agentControl.rawValue, forKey: "settingsPage")
        render(SettingsView(), width: 1100, height: 760, name: "agent-control")
        UserDefaults.standard.set(SettingsPage.activity.rawValue, forKey: "settingsPage")
        render(SettingsView(), width: 1100, height: 760, name: "activity")
        UserDefaults.standard.set(SettingsPage.internet.rawValue, forKey: "settingsPage")
        render(SettingsView(), width: 1100, height: 1100, name: "internet")
        UserDefaults.standard.set(saved, forKey: "settingsPage")
        exit(0)
    }
}
