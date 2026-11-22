// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit
import Security
import SwiftUI
import UserNotifications
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

        // 0.5: one window, "Kai" (Now, Activity, Ask Kai, Settings). The old
        // id stays so kai://settings links keep working.
        Window("Kai", id: "settings") {
            MainWindowView()
                .environmentObject(model)
                .environmentObject(wall)
                .environmentObject(storage)
        }
        .defaultSize(width: 1080, height: 720)

        // 0.5: first launch only (Onboarding.done).
        Window("Welcome to Kai", id: "onboarding") {
            OnboardingView()
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
    static let isRelease: Bool = {
        #if DEBUG
        if ScreenshotFixture.active { return true }   // no DEV badge in README pictures
        #endif
        return kai_app_is_release(Bundle.main.bundlePath, ownTeamID()) == 1
    }()

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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var lockFD: Int32 = -1

    // Dogfood: card notifications show even while Kai is active, and their
    // buttons answer the card.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["pending"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if let id, action == "ALLOW" || action == "KEEP" {
                GrantManager.shared.answerFromNotification(pendingID: id, allow: action == "ALLOW")
            }
            done()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Snapshot.requestedDir != nil { return }   // rendering only: no lock
        #if DEBUG
        if ScreenshotFixture.active { return }      // make screenshots: fixture only, no lock
        #endif
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
        LocalModelChoice.register()
        #if DEBUG
        if let dir = ScreenshotFixture.outDir { Task { @MainActor in await ScreenshotRenderer.run(to: dir) }; return }
        #endif
        if Snapshot.requestedDir == nil && Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.registerCategories()
            Notifier.requestPermission()   // Nov 2: ask on first launch (macOS asks once, then remembers)
            _ = GrantManager.shared   // cards notify from launch, popover opened or not
        }
        if let dir = Snapshot.requestedDir { Task { @MainActor in await Snapshot.run(to: dir) } }
        // v1 has no control service: this app writes policy and permissions
        // in-process; the CLI only reads them.
    }

    /// kai://settings/<page> (the CLI's "Change this in Kai"), kai://now,
    /// kai://activity[/stops], kai://ask; 0.4's kai://decisions and
    /// kai://agents redirect (KaiRoute).
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            guard let r = KaiRoute.from(u) else { continue }
            if case .settings(let p) = r { UserDefaults.standard.set(p.rawValue, forKey: "settingsPage") }
            Task { @MainActor in MainNav.shared.go(r) }
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
            .accessibilityLabel("Kai: \(model.health == .problem ? model.headline : model.headline(AgentsModel.shared).words)")
            .onReceive(NotificationCenter.default.publisher(for: .kaiOpenSettings)) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .task {
                // 0.5: the short onboarding, once.
                guard Snapshot.requestedDir == nil, !Onboarding.done, Bundle.main.bundleIdentifier != nil else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
