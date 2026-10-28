// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Advertises the control Mach service (Step 3) so the `kai` CLI can look it up.
// A listener that a process merely creates is not reachable by other processes
// until launchd owns the name; a LaunchAgent bundled in the app declares it. We
// register that agent with SMAppService. The app then checks the listener in
// via kai_control_service_start().
//
// This registration is the one part of the control path that must be validated
// live on a signed build (see docs/audit/live-tests/step3-xpc.md): the security
// decision (who may write) is made in C from the caller's audit token and is
// unit-tested; this file is only how the socket becomes reachable.
import Foundation
import ServiceManagement
import os

enum ControlServiceAgent {
    static let plistName = "io.github.sameehj.kai.controlservice.plist"
    private static let log = Logger(subsystem: "io.github.sameehj.kai", category: "control")

    /// Called only by the release instance (/Applications/Kai.app). Always
    /// re-registers, so the service points at THIS app: any other copy that
    /// registered it (live: an old build/Kai.app had taken it, launchd kept
    /// failing to start it, and every `kai policy` call hung) is replaced.
    static func registerIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.agent(plistName: plistName)
        svc.unregister { _ in
            do {
                try svc.register()
                log.info("control-service agent registered to the installed app")
            } catch {
                // Non-fatal: the app UI still writes policy and grants in-process.
                // Only the CLI -> service path needs the agent, and the CLI reports a
                // clear "open Kai" message if it can't reach the service.
                log.error("control agent register failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
