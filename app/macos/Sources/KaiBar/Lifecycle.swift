// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// C5 / §2.6: repair, owned by the app and independent of a broken CLI or hook.
// The package installs Kai's program at /usr/local/bin/kai and the hook
// launcher at /usr/local/libexec/kai-hook; the agents' hooks call the
// launcher. Repair puts a missing program back from the copy inside Kai.app
// (one admin prompt) and then rewrites the hooks with `kai doctor --fix`. It
// never points the hooks into the app bundle: trashing the app must not leave
// them calling a missing program.
import AppKit
import Foundation

enum Lifecycle {
    static let programPath = "/usr/local/bin/kai"
    static let launcherPath = "/usr/local/libexec/kai-hook"

    /// The kai inside this Kai.app (Contents/Resources/kai), if any.
    static var bundledProgram: String? { Bundle.main.url(forResource: "kai", withExtension: nil)?.path }

    /// The hooks can't run Kai: the package's launcher is there but the
    /// program it runs is gone. (No launcher at all is a different install:
    /// `kai snapshot` reports those hooks as failing when they can't run.)
    static var programMissing: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: launcherPath) && !fm.isExecutableFile(atPath: programPath)
    }

    /// 'text' for /bin/sh.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs one shell command as root behind ONE macOS admin prompt.
    @MainActor
    static func runAsAdmin(_ command: String, prompt: String) -> (ok: Bool, message: String) {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with prompt \"\(p)\" with administrator privileges"
        var err: NSDictionary?
        guard let script = NSAppleScript(source: src) else { return (false, "couldn't prepare the admin prompt") }
        script.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return (false, "cancelled") }
            return (false, err[NSAppleScript.errorMessage] as? String ?? "failed (\(code))")
        }
        return (true, "")
    }

    /// Repair: program first (from the app's copy), then the hooks. Returns
    /// one plain sentence per step.
    @MainActor
    static func repair() async -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: programPath) {
            if !fm.fileExists(atPath: launcherPath) {
                out.append("Kai's hook launcher (\(launcherPath)) is missing and Kai.app doesn't carry one: reinstall the Kai package.")
            } else if let src = bundledProgram {
                let cmd = "/bin/mkdir -p /usr/local/bin && /bin/cp -f \(shellQuote(src)) \(shellQuote(programPath))"
                    + " && /bin/chmod 755 \(shellQuote(programPath))"
                let r = runAsAdmin(cmd, prompt: "Kai wants to put its program back at \(programPath) so the agents' checks can run.")
                out.append(r.ok ? "Put Kai's program back at \(programPath)." : "Kai's program wasn't put back: \(r.message).")
            } else {
                out.append("Kai's program is missing and this Kai.app doesn't carry a copy: reinstall the Kai package.")
            }
        }
        let r = await KaiCLI.run(["doctor", "--fix"])
        out.append(r.ok ? "Hooks checked and repaired." : "Hooks weren't repaired: \(r.message)")
        return out
    }
}
