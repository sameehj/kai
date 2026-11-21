// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Turns Kai's network system extension on and off: asks macOS to activate the
// extension (the user approves once in System Settings), then registers it as
// the content filter. The extension itself lives in app/macos/Network.
import AppKit
import Foundation
import NetworkExtension
import SystemExtensions
import KaiCore

@MainActor
final class NetworkWall: NSObject, ObservableObject {
    /// B3: the state word Settings shows, from macOS's answer and the
    /// measured heartbeat.
    var stateWord: String {
        let os: Int32
        switch state {
        case .needsApproval: os = Int32(KAI_WALL_OS_NOT_INSTALLED)
        case .off: os = Int32(KAI_WALL_OS_OFF)
        case .checking, .activating, .allowFilter: os = Int32(KAI_WALL_OS_STARTING)
        case .failed: os = Int32(KAI_WALL_OS_FAILED)
        case .on: os = Int32(KAI_WALL_OS_ON)
        }
        return String(cString: kai_wall_state_word(os, kai_wall_observed_level("network")))
    }

    enum State: Equatable {
        case checking
        case off
        case activating
        case needsApproval
        /// 0.4.1: the extension is approved; macOS is asking "Kai would like
        /// to filter network content" (Allow / Don't Allow).
        case allowFilter
        case on
        case failed(String)
    }

    static let extensionID = "io.github.sameehj.kai.network"
    @Published private(set) var state: State = .checking

    var isOn: Bool { state == .on }

    var summary: String {
        switch state {
        case .checking: return "Checking…"
        case .off: return "Off"
        case .activating: return "Turning on…"
        case .needsApproval: return "macOS needs your OK in System Settings"
        case .allowFilter: return "macOS is asking to allow filtering: click Allow"
        case .on: return "On: Kai checks where agents connect"
        case .failed(let msg): return msg
        }
    }

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let m = NEFilterManager.shared()
                let enabled = error == nil && m.providerConfiguration != nil && m.isEnabled
                // Waiting for the user (System Settings, or the filter alert):
                // only a filter that is now on ends the wait.
                if self.state == .needsApproval || self.state == .allowFilter || self.state == .activating {
                    if enabled { self.state = .on; Self.markOn(true) }
                    return
                }
                if let error { self.state = .failed(Self.plain(error)); return }
                self.state = (m.providerConfiguration != nil && m.isEnabled) ? .on : .off
                if self.state == .on { self.updateExtensionOnce() }
            }
        }
    }

    /// The version of the network extension this Kai.app carries, read from the
    /// embedded .systemextension bundle. It changes only when the extension's
    /// own code does (its CFBundleVersion is KAI_EXT_VERSION, separate from the
    /// app's), so an app-only update leaves it unchanged.
    private var embeddedExtensionVersion: String? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.pathExtension == "systemextension" {
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               let v = info["CFBundleVersion"] as? String { return v }
        }
        return nil
    }

    /// Re-submit activation only when the carried extension is actually newer
    /// than the one macOS is already running. Replacing a system extension
    /// tears down its content filter, which drops every open connection,
    /// including agents' live API requests — so we never do it for an
    /// app-only update. macOS still won't replace same-version extensions, but
    /// skipping the request avoids even that round-trip and any edge cases.
    private static let activatedVersionKey = "kaiActivatedExtensionVersion"
    private var updateRequested = false
    private func updateExtensionOnce() {
        guard !updateRequested, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        updateRequested = true
        guard let carried = embeddedExtensionVersion else { return }
        // Skip only when we already activated exactly this extension version:
        // then nothing changed and there is nothing to do. Otherwise submit —
        // macOS no-ops a same-version request (no filter teardown) and only
        // replaces, once, when the version genuinely rose.
        if UserDefaults.standard.string(forKey: Self.activatedVersionKey) == carried { return }
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID,
                                                             queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// 0.3: <kai home>/internet.on says the user turned Internet on, so `kai
    /// doctor` reports a missing extension as a problem only then (otherwise
    /// "Internet: off (opt-in in Settings)"). Agents can't write Kai's home.
    static func markOn(_ on: Bool) {
        let path = String(cString: kai_home()) + "/internet.on"
        if on { FileManager.default.createFile(atPath: path, contents: Data("on\n".utf8)) }
        else { try? FileManager.default.removeItem(atPath: path) }
    }

    /// macOS errors in plain words (the step shows them with Try again).
    static func plain(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == OSSystemExtensionErrorDomain {
            switch ns.code {
            case 4: return "This Kai build doesn't include the Internet extension"
            case 8: return "macOS didn't allow Kai's extension (it was declined or is waiting in System Settings)"
            case 9: return "macOS needs Kai.app to be in /Applications to load its extension"
            case 1, 3: return "macOS couldn't load Kai's extension; restart the Mac and try again"
            default: break
            }
        }
        if ns.domain == NEFilterErrorDomain {
            return "macOS didn't allow Kai to filter network content (Don't Allow was chosen, or a profile blocks it)"
        }
        return ns.localizedDescription
    }

    /// System Settings where macOS lists blocked system software. macOS 15+:
    /// General → Login Items & Extensions; macOS 13–14: Privacy & Security.
    static func openApprovalSettings() {
        let v = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let urls = v >= 15
            ? ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
               "x-apple.systempreferences:com.apple.ExtensionsPreferences"]
            : ["x-apple.systempreferences:com.apple.preference.security?General",
               "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    func turnOn() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            state = .failed("Move Kai.app to /Applications first (macOS only loads extensions from there)")
            return
        }
        state = .activating
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID,
                                                             queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// Off means off: the filter is disabled AND removed from the system's
    /// network settings (it no longer shows under VPN & Filters).
    func turnOff() {
        let m = NEFilterManager.shared()
        m.loadFromPreferences { [weak self] error in
            if let error {
                Task { @MainActor in self?.state = .failed(error.localizedDescription) }
                return
            }
            m.isEnabled = false
            m.saveToPreferences { _ in
                m.removeFromPreferences { error in
                    Task { @MainActor in
                        if let error { self?.state = .failed(error.localizedDescription) } else { self?.state = .off; Self.markOn(false) }
                    }
                }
            }
        }
    }

    /// Uninstall (C5): disable and remove the filter, then ask macOS to
    /// deactivate the extension. `done` gets one line per step.
    func removeForUninstall(_ done: @escaping @MainActor ([String]) -> Void) {
        let m = NEFilterManager.shared()
        m.loadFromPreferences { [weak self] error in
            var lines: [String] = []
            if let error { lines.append("Internet filter: couldn't read its settings (\(error.localizedDescription)).") }
            let hadFilter = m.providerConfiguration != nil
            m.isEnabled = false
            m.saveToPreferences { _ in
                m.removeFromPreferences { error in
                    Task { @MainActor in
                        if !hadFilter { lines.append("Internet filter: none was set up.") }
                        else if let error { lines.append("Internet filter: not removed (\(error.localizedDescription)).") }
                        else { lines.append("Internet filter: turned off and removed.") }
                        self?.state = .off
                        Self.markOn(false)
                        self?.deactivate { lines.append($0); done(lines) }
                    }
                }
            }
        }
    }

    private var deactivateDone: (@MainActor (String) -> Void)?
    private func deactivate(_ done: @escaping @MainActor (String) -> Void) {
        deactivateDone = done
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// After the extension is active, register it as the system's content filter.
    private func enableFilter() {
        let m = NEFilterManager.shared()
        m.loadFromPreferences { [weak self] error in
            if let error {
                Task { @MainActor in self?.state = .failed(error.localizedDescription) }
                return
            }
            let config = NEFilterProviderConfiguration()
            config.filterSockets = true
            config.filterPackets = false
            // The extension runs as root: tell it whose policy and audit log to use.
            config.vendorConfiguration = [
                "home": NSHomeDirectory(),
                "uid": Int(getuid()),
                "gid": Int(getgid()),
            ]
            m.providerConfiguration = config
            m.localizedDescription = "Kai"
            m.isEnabled = true
            // macOS shows "Kai would like to filter network content" now.
            Task { @MainActor in self?.state = .allowFilter }
            m.saveToPreferences { error in
                Task { @MainActor in
                    if let error { self?.state = .failed(Self.plain(error)) } else { self?.state = .on; Self.markOn(true) }
                }
            }
        }
    }
}

extension NetworkWall: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace // a newer Kai.app updates its extension
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if let d = self.deactivateDone {
                self.deactivateDone = nil
                d(result == .willCompleteAfterReboot ? "Internet extension: Restart needed to finish removing it."
                                                     : "Internet extension: removed.")
                return
            }
            // Remember what's now running, so we don't reactivate it next launch.
            if let v = self.embeddedExtensionVersion {
                UserDefaults.standard.set(v, forKey: Self.activatedVersionKey)
            }
            self.enableFilter()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            if let d = self.deactivateDone {
                self.deactivateDone = nil
                let ns = error as NSError
                // 4 = not found: it was never installed, nothing to remove
                d(ns.domain == OSSystemExtensionErrorDomain && ns.code == 4 ? "Internet extension: not installed."
                  : "Internet extension: still listed (\(ns.localizedDescription)).")
                return
            }
            self.state = .failed(Self.plain(error))
        }
    }
}
