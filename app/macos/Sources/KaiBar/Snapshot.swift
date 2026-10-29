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
