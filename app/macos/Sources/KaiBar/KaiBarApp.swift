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
        // The launchd-started control-service instance runs with no icon: one
        // visible Kai, plus the background service.
        MenuBarExtra(isInserted: .constant(!KaiInstance.isControlAgent)) {
            MenuView()
                .environmentObject(model)
                .environmentObject(wall)
                .environmentObject(storage)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Kai: \(model.health == .problem ? model.headline : model.statusSentence(storageOn: storage.isOn, networkOn: wall.isOn))")
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
    /// Only it hosts the control service; any other copy is a DEV copy.
    static let isRelease: Bool = kai_app_is_release(Bundle.main.bundlePath, ownTeamID()) == 1

    /// launchd starts a separate instance of the app to host the control
    /// service (its LaunchAgent; launchd sets XPC_SERVICE_NAME to the label).
    /// That one must NOT hand over to the menu-bar instance - it's the only one
    /// that can check the service in - and shows no menu-bar icon.
    static let isControlAgent: Bool =
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == KAI_CONTROL_MACH_NAME

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
        if KaiInstance.isControlAgent { return }   // the background service, not a second UI
        // One menu-bar Kai: an exclusive lock in Kai's home, held for the app's
        // life, taken only by menu-bar instances (never the launchd-started
        // control service, which is also this app). A second copy that can't
        // take it activates the running one and quits.
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
        // The one authenticated control path (Step 3): the app is the sole
        // writer of the policy store. Start its XPC service so the `kai` CLI can
        // ask it to make changes. The Mach name must be advertised by the app's
        // launchd agent for CLI lookups to reach it (see ControlServiceAgent).
        // Only the release instance: a DEV copy never hosts it or registers
        // its LaunchAgent.
        guard KaiInstance.isRelease else { return }
        ControlServiceAgent.registerIfNeeded()
        _ = kai_control_service_start()
    }
}
