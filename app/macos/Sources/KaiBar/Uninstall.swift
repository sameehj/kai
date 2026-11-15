// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// C5 (redesign §5): one measured uninstall, owned by the app. Each step runs
// in order and reports what it found, then the page lists anything left:
//   1. remove the agents' hooks (`kai uninstall all`) and verify the files
//   2. turn the Internet filter off and remove its configuration
//   3. ask macOS to deactivate Kai's network extension ("restart needed" when
//      macOS keeps it until the next restart)
//   4. remove Kai's program and hook launcher behind ONE admin prompt
//   5. report leftovers
// Kai's history (~/.kai) is the user's data: it is listed, never deleted here.
import AppKit
import Foundation
import SwiftUI

enum UninstallSteps {
    /// Files the package installs (scripts/release/build-preview-pkg.sh).
    static let packageFiles = [Lifecycle.cliLink, Lifecycle.launcherPath, Lifecycle.programDir, "/usr/local/share/kai"]
    static let packageID = "io.github.sameehj.kai.preview"

    /// The hook settings files Kai installs into, and whether each still runs Kai.
    static func hookFilesStillCallingKai() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex"
        let files = ["\(home)/.claude/settings.json", "\(home)/.cursor/hooks.json", "\(codex)/hooks.json"]
        return files.filter { f in
            guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { return false }
            return t.contains("kai-hook") || t.contains(" hook claude") || t.contains(" hook cursor")
                || t.contains(" hook codex")
        }
    }

    /// What `systemextensionsctl list` says about Kai's extensions, one line each.
    static func extensionLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        p.arguments = ["list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.contains("io.github.sameehj.kai") }
    }

    /// One shell command (run as root) that removes the package's files and its receipt.
    static var removeCommand: String {
        let rm = packageFiles.map { "/bin/rm -rf " + Lifecycle.shellQuote($0) }.joined(separator: " ; ")
        return rm + " ; /usr/sbin/pkgutil --forget " + packageID + " >/dev/null 2>&1 ; true"
    }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published var lines: [(ok: Bool, text: String)] = []
    @Published var leftovers: [String] = []
    @Published var running = false
    @Published var finished = false

    private func say(_ ok: Bool, _ t: String) { lines.append((ok, t)) }

    func run(wall: NetworkWall) async {
        running = true
        lines = []
        leftovers = []
        // 1. hooks
        let r = await KaiCLI.run(["uninstall", "all"])
        let still = UninstallSteps.hookFilesStillCallingKai()
        if still.isEmpty {
            say(true, "Agents' hooks removed and checked: no hook settings file runs Kai.")
        } else {
            say(false, "Hooks still run Kai in: " + still.joined(separator: ", ")
                + (r.ok ? "" : " (kai uninstall said: \(r.message))"))
        }
        // 2 + 3. Internet filter and network extension
        let netLines: [String] = await withCheckedContinuation { cont in
            wall.removeForUninstall { cont.resume(returning: $0) }
        }
        for l in netLines {
            let bad = l.contains("not removed") || l.contains("couldn't") || l.contains("failed")
            say(!bad, l)
        }
        // 4. program and launcher, one admin prompt
        let present = UninstallSteps.packageFiles.filter { Lifecycle.exists($0) }
        if present.isEmpty {
            say(true, "Kai's program and hook launcher: already gone.")
        } else {
            let a = Lifecycle.runAsAdmin(UninstallSteps.removeCommand,
                                         prompt: "Kai wants to remove its program and hook launcher from this Mac.")
            say(a.ok, a.ok ? "Removed " + present.joined(separator: ", ") + "."
                          : "Kai's program and launcher weren't removed: \(a.message).")
        }
        // 5. leftovers
        var left: [String] = []
        for f in UninstallSteps.packageFiles where Lifecycle.exists(f) { left.append("\(f) is still there.") }
        for f in UninstallSteps.hookFilesStillCallingKai() { left.append("\(f) still runs Kai's hook.") }
        let ext = UninstallSteps.extensionLines()
        if ext.contains(where: { $0.contains("waiting to uninstall") }) {
            left.append("Restart needed: macOS removes Kai's network extension at the next restart.")
        } else if !ext.isEmpty {
            left.append("macOS still lists Kai's extension: " + ext.joined(separator: "; "))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if FileManager.default.fileExists(atPath: "\(home)/.kai") {
            left.append("Your Kai history and settings are kept in ~/.kai. Delete that folder yourself if you don't want them.")
        }
        left.append("Last step: quit Kai and move Kai.app to the Trash.")
        leftovers = left
        running = false
        finished = true
    }
}

struct UninstallPage: View {
    @EnvironmentObject var wall: NetworkWall
    @StateObject private var model = UninstallModel()
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.system(size: 22)).foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Kai").font(Theme.display(24))
                    Text("Removes Kai from your agents and from this Mac, checks each step, and lists anything left.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What happens").font(.system(size: 13, weight: .semibold))
                    ForEach(["1. Remove Kai's hooks from Claude Code, Cursor and Codex, then check the files.",
                             "2. Turn the Internet filter off and remove its configuration.",
                             "3. Ask macOS to remove Kai's network extension (it may need a restart).",
                             "4. Remove Kai's program and hook launcher (one admin prompt).",
                             "5. List anything left, including \u{201C}restart needed\u{201D}."], id: \.self) {
                        Text($0).font(.system(size: 12)).foregroundStyle(Theme.soft)
                    }
                    Text("After this, Kai checks nothing. Your agents keep working.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
                }
            }
            if !model.finished {
                if confirm {
                    HStack(spacing: 8) {
                        Button(model.running ? "Uninstalling…" : "Yes, uninstall Kai") {
                            Task { await model.run(wall: wall) }
                        }
                        .buttonStyle(WhiteButtonStyle()).disabled(model.running)
                        Button("Cancel") { confirm = false }.buttonStyle(GhostButtonStyle()).disabled(model.running)
                    }
                } else {
                    Button("Uninstall Kai…") { confirm = true }.buttonStyle(GhostButtonStyle())
                }
            }
            if !model.lines.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: l.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                    .foregroundStyle(l.ok ? Theme.lime : Theme.amber)
                                Text(l.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if model.finished {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Left on this Mac").font(.system(size: 13, weight: .semibold))
                        ForEach(model.leftovers, id: \.self) {
                            Text("• " + $0).font(.system(size: 12)).foregroundStyle(Theme.soft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
