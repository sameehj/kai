// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import SwiftUI

@main
struct KaiBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var wall = NetworkWall()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(wall)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Kai: \(model.headline)")
        }
        .menuBarExtraStyle(.window)

        Window("Kai Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(wall)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon even when run outside a bundle.
        NSApp.setActivationPolicy(.accessory)
    }
}
