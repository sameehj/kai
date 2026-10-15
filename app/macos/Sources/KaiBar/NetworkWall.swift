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

    /// When the wall is on, re-submit activation once per launch. If this
    /// Kai.app carries a newer extension, macOS swaps it in (no new approval
    /// for the same team); if not, the request just completes.
    private var updateRequested = false
    private func updateExtensionOnce() {
        guard !updateRequested, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        updateRequested = true
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
        Task { @MainActor in self.enableFilter() }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}
