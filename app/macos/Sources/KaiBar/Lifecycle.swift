// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// C5 / §2.6: repair, owned by the app and independent of a broken CLI or hook.
// The package installs Kai's program in a root-owned folder,
// /Library/Application Support/Kai/bin/kai (Nov 15: /usr/local/bin is often the
// user's own, so any program could delete a kai there), with
// /usr/local/bin/kai as a symlink for the Terminal, and the hook launcher at
// /usr/local/libexec/kai-hook; the agents' hooks call the launcher. Repair puts a missing program back from the copy inside Kai.app
// (one admin prompt) and then rewrites the hooks with `kai doctor --fix`. It
// never points the hooks into the app bundle: trashing the app must not leave
// them calling a missing program.
import AppKit
import Foundation

enum Lifecycle {
    static let programDir = "/Library/Application Support/Kai"
    static let programPath = "/Library/Application Support/Kai/bin/kai"
    static let cliLink = "/usr/local/bin/kai"
    static let launcherPath = "/usr/local/libexec/kai-hook"

    /// The path exists, itself (a dangling symlink counts).
    static func exists(_ path: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: path)) != nil }

    /// The kai inside this Kai.app (Contents/Resources/kai), if any.
    static var bundledProgram: String? { Bundle.main.url(forResource: "kai", withExtension: nil)?.path }
    /// The hook launcher inside this Kai.app (Contents/Resources/kai-hook), if any.
    static var bundledLauncher: String? { Bundle.main.url(forResource: "kai-hook", withExtension: nil)?.path }

    /// The hooks can't run Kai: the package's launcher is there but the
    /// program it runs is gone. (No launcher at all is a different install:
    /// `kai snapshot` reports those hooks as failing when they can't run.)
    static var programMissing: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: launcherPath) { return !fm.isExecutableFile(atPath: programPath) }
        // No launcher, but the hooks still call it: every hook fails (C1 lets
        // the agent through; nothing is checked).
        return !UninstallSteps.hookFilesStillCallingKai().filter { f in
            (try? String(contentsOfFile: f, encoding: .utf8))?.contains(launcherPath) == true
        }.isEmpty
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

    /// Repair: put back whatever the hooks need, from the copies inside Kai.app,
    /// behind ONE admin prompt (program and/or launcher), then rewrite the
    /// hooks with `kai doctor --fix`, which points them at the launcher, never
    /// into the app bundle. Returns one plain sentence per step.
    @MainActor
    static func repair() async -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        var cmds: [String] = [], what: [String] = [], missing: [String] = []
        if !fm.isExecutableFile(atPath: launcherPath) {
            if let src = bundledLauncher {
                cmds.append("/bin/mkdir -p /usr/local/libexec && /bin/cp -f \(shellQuote(src)) \(shellQuote(launcherPath))"
                            + " && /usr/sbin/chown root:wheel \(shellQuote(launcherPath)) && /bin/chmod 755 \(shellQuote(launcherPath))")
                what.append("hook launcher")
            } else { missing.append("hook launcher") }
        }
        if !fm.isExecutableFile(atPath: programPath) {
            if let src = bundledProgram {
                // root-owned, not group-writable, all the way down; then the Terminal's symlink
                let dir = (programPath as NSString).deletingLastPathComponent
                cmds.append("/bin/mkdir -p \(shellQuote(dir)) && /bin/cp -f \(shellQuote(src)) \(shellQuote(programPath))"
                            + " && /usr/sbin/chown root:wheel \(shellQuote(programDir)) \(shellQuote(dir)) \(shellQuote(programPath))"
                            + " && /bin/chmod 755 \(shellQuote(programDir)) \(shellQuote(dir)) \(shellQuote(programPath))"
                            + " && /bin/mkdir -p /usr/local/bin && /bin/ln -sfh \(shellQuote(programPath)) \(shellQuote(cliLink))")
                what.append("program")
            } else { missing.append("program") }
        }
        if !missing.isEmpty {
            out.append("This Kai.app doesn't carry Kai's \(missing.joined(separator: " or ")): reinstall the Kai package.")
        }
        if !cmds.isEmpty {
            let r = runAsAdmin(cmds.joined(separator: " && "),
                               prompt: "Kai wants to put back its \(what.joined(separator: " and ")) so the agents' checks can run.")
            out.append(r.ok ? "Put back Kai's \(what.joined(separator: " and "))." : "Kai's \(what.joined(separator: " and ")) wasn't put back: \(r.message).")
        }
        let r = await KaiCLI.run(["doctor", "--fix"])
        out.append(r.ok ? "Hooks checked and repaired." : "Hooks weren't repaired: \(r.message)")
        return out
    }
}
