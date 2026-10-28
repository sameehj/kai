// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import Security
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
            MenuBarLabel(model: model, wall: wall, storage: storage)
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

/// One Kai. A second copy isn't just confusing: any copy signed with the
/// Team ID could try to host the control service (the only writer of policy
/// and permissions) with old rules, and an agent can launch one.
enum KaiInstance {
    /// The release instance: /Applications/Kai.app with the release signature.
    /// Any other copy is a DEV copy (badge; the storage wall lets only the
    /// installed app write policy and permissions).
    static let isRelease: Bool = kai_app_is_release(Bundle.main.bundlePath, ownTeamID()) == 1

    static func ownTeamID() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "" }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &st) == errSecSuccess, let st else { return "" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let d = info as? [String: Any] else { return "" }
        return d[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lockFD: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One menu-bar Kai: an exclusive lock in Kai's home, held for the app's
        // life. A second copy that can't take it activates the running one and
        // quits.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        lockFD = kai_app_lock_acquire(home + "/.kai/run/app.lock")
        if lockFD < 0 {
            let me = NSRunningApplication.current
            if let id = Bundle.main.bundleIdentifier {
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .filter { $0.processIdentifier != me.processIdentifier }
                    .forEach { $0.activate() }
            }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon even when run outside a bundle.
        NSApp.setActivationPolicy(.accessory)
        // v1 has no control service: this app writes policy and permissions
        // in-process; the CLI only reads them.
    }

    /// kai://settings/<page> - the CLI's "Change this in Kai" opens the page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "kai" && u.host == "settings" {
            let page = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            UserDefaults.standard.set(SettingsPage(stored: page).rawValue, forKey: "settingsPage")
            NotificationCenter.default.post(name: .kaiOpenSettings, object: nil)
        }
    }
}

extension Notification.Name { static let kaiOpenSettings = Notification.Name("kaiOpenSettings") }

/// The menu-bar icon. It is always on screen, so it is also where a
/// kai://settings link opens the Settings window.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var wall: NetworkWall
    @ObservedObject var storage: StorageWall
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel("Kai: \(model.health == .problem ? model.headline : model.statusSentence(storageOn: storage.isOn, networkOn: wall.isOn))")
            .onReceive(NotificationCenter.default.publisher(for: .kaiOpenSettings)) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
