// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Turns Kai's storage system extension (Endpoint Security) on and off, the
// same way NetworkWall does for the network extension: ask macOS to activate
// it, the user approves once in System Settings, and from then on the OS keeps
// it running. The extension reads the policy itself and decides via the C
// engine; this class only activates/deactivates and reports state.
//
// The extension is present only in a storage build (make try-app-storage).
// In a normal build activation fails with "extension not found", which we
// surface rather than pretend the control works.
import Foundation
import SystemExtensions

@MainActor
final class StorageWall: NSObject, ObservableObject {
    enum State: Equatable {
        case checking, off, activating, needsApproval, on, failed(String)
    }

    static let extensionID = "io.github.sameehj.kai.storage"
    @Published private(set) var state: State = .off
    private var turningOff = false

    var isOn: Bool { state == .on }

    var summary: String {
        switch state {
        case .checking: return "Checking…"
        case .off: return "Off"
        case .activating: return "Turning on…"
        case .needsApproval: return "Approve Kai in System Settings → Privacy & Security"
        case .on: return "On: agents can't open protected files"
        case .failed(let m): return m
        }
    }

    func turnOn() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            state = .failed("Move Kai.app to /Applications first")
            return
        }
        turningOff = false
        state = .activating
        submit(activate: true)
    }

    func turnOff() {
        turningOff = true
        submit(activate: false)
    }

    private func submit(activate: Bool) {
        let req = activate
            ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }
}

extension StorageWall: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.state = self.turningOff ? .off : .on }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Code 4 = extension not found (a non-storage build); say so plainly.
            let ns = error as NSError
            if ns.domain == OSSystemExtensionErrorDomain && ns.code == 4 {
                self.state = .failed("This Kai build has no storage extension (use make try-app-storage)")
            } else {
                self.state = self.turningOff ? .off : .failed(ns.localizedDescription)
            }
        }
    }
}
