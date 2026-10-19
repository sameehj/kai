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
import AppKit
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

    // MARK: making the two required approvals one-click

    /// The extension can't start until the user grants Full Disk Access
    /// (es_new_client returns NOT_PERMITTED). It records that in its status
    /// file; read the latest state so the UI can show exactly what's left and
    /// flip to "on" by itself once the grant lands.
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var runtimeNote = ""

    func refreshRuntime() {
        guard let text = try? String(contentsOfFile: "/tmp/kai-storage.log", encoding: .utf8) else {
            needsFullDiskAccess = false; runtimeNote = ""; return
        }
        let lines = text.split(separator: "\n").suffix(40).map(String.init)
        // The most recent of these outcomes wins.
        var enforcing = false, notPermitted = false
        for l in lines {
            if l.contains("enforcing in mode") { enforcing = true; notPermitted = false }
            else if l.contains("NOT_PERMITTED") { notPermitted = true; enforcing = false }
        }
        needsFullDiskAccess = notPermitted && !enforcing
        if enforcing { runtimeNote = "Endpoint Security client running." }
        else if notPermitted { runtimeNote = "Waiting for Full Disk Access." }
        else { runtimeNote = "" }
    }

    /// Open System Settings straight to the Full Disk Access list.
    func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Open the system-extension approval pane (Login Items & Extensions / Privacy & Security).
    func openExtensionApprovalSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(u)
        }
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
