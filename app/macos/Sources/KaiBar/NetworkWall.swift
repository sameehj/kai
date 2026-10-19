// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Turns Kai's network system extension on and off: asks macOS to activate the
// extension (the user approves once in System Settings), then registers it as
// the content filter. The extension itself lives in app/macos/Network.
import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class NetworkWall: NSObject, ObservableObject {
    enum State: Equatable {
        case checking
        case off
        case activating
        case needsApproval
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
        case .needsApproval: return "Approve Kai in System Settings → Privacy & Security"
        case .on: return "On: agent traffic is checked"
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
                if case .needsApproval = self.state { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                let m = NEFilterManager.shared()
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

    func turnOff() {
        let m = NEFilterManager.shared()
        m.loadFromPreferences { [weak self] _ in
            m.isEnabled = false
            m.saveToPreferences { error in
                Task { @MainActor in
                    if let error { self?.state = .failed(error.localizedDescription) } else { self?.state = .off }
                }
            }
        }
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
            m.saveToPreferences { error in
                Task { @MainActor in
                    if let error { self?.state = .failed(error.localizedDescription) } else { self?.state = .on }
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
            // Remember what's now running, so we don't reactivate it next launch.
            if let v = self.embeddedExtensionVersion {
                UserDefaults.standard.set(v, forKey: Self.activatedVersionKey)
            }
            self.enableFilter()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}
