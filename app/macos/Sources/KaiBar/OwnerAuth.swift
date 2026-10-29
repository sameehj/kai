// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// B2: owner authentication only where it buys real safety. Touch ID or Apple
// Watch where available, else the login password (.deviceOwnerAuthentication).
//
//   one click, no prompt   Allow for this session, Keep blocked, Revoke, Pause 15 min
//   owner authentication   Files or Internet to Watch or Off; creating a rule
//   every time             break-glass access to secrets (SSH keys, cloud credentials)
//
// One authentication covers 30 minutes of further protection-lowering actions
// (never break-glass) while the Mac stays unlocked; locking or sleeping the
// Mac resets it.
import AppKit
import LocalAuthentication

final class OwnerAuth {
    static let shared = OwnerAuth()
    static let window: TimeInterval = 30 * 60

    private var until: Date?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let reset: (Notification) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.until = nil } }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                  NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main, using: reset))
        }
        observers.append(DistributedNotificationCenter.default()
            .addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                         queue: .main, using: reset))
    }

    /// Is a protection-lowering action covered right now without a prompt?
    var covered: Bool { (until ?? .distantPast) > Date() }

    /// Ask the owner. `everyTime` (break-glass) never uses or extends the window.
    func confirm(_ reason: String, everyTime: Bool = false) async -> Bool {
        if !everyTime && covered { return true }
        let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                         localizedReason: reason)) ?? false
        if ok && !everyTime { await MainActor.run { until = Date().addingTimeInterval(Self.window) } }
        return ok
    }
}
