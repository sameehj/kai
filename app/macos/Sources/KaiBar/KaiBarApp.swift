// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI
import KaiCore

@main
struct KaiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var wall = NetworkWall()
    @StateObject private var storage = StorageWall()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(wall)
                .environmentObject(storage)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Kai: \(model.headline)")
        }
        .menuBarExtraStyle(.window)

        Window("Kai Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(wall)
                .environmentObject(storage)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon even when run outside a bundle.
        NSApp.setActivationPolicy(.accessory)
        // The one authenticated control path (Step 3): the app is the sole
        // writer of the policy store. Start its XPC service so the `kai` CLI can
        // ask it to make changes. The Mach name must be advertised by the app's
        // launchd agent for CLI lookups to reach it (see ControlServiceAgent).
        ControlServiceAgent.registerIfNeeded()
        _ = kai_control_service_start()
    }
}
