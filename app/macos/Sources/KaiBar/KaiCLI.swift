// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import Foundation

/// Output of `kai status --json`.
struct KaiStatus: Decodable, Equatable {
    struct Policy: Decodable, Equatable {
        let ok: Bool
        let source: String
        let file: String
        let fileExists: Bool
        let error: String
    }
    struct Agent: Decodable, Equatable {
        let installed: Bool
        let detected: Bool
        let config: String
        var extensionLoaded: Bool? = nil // chrome only
        /// Live check (kai status runs the installed hook): nil from older kai CLIs.
        var working: Bool? = nil
        var problem: String? = nil
        /// Installed, checked, and not working right now.
        var broken: Bool { installed && working == false }
    }
    struct Audit: Decodable, Equatable {
        let path: String
        let records: Int
        let intact: Bool
        let error: String
    }
    /// Configured-vs-observed wall state (U1: the headline must reflect observed
    /// enforcement, not what the policy is set to). Absent on older kai CLIs.
    struct Walls: Decodable, Equatable {
        struct Health: Decodable, Equatable {
            var mode: String? = nil         // off | log | block
            var enforcing: Bool? = nil
        }
        struct WallObs: Decodable, Equatable {
            var running: Bool? = nil
            var health: Health? = nil
        }
        struct Configured: Decodable, Equatable {
            var storage: String? = nil
            var network: String? = nil
        }
        struct Observed: Decodable, Equatable {
            var storage: WallObs? = nil
            var network: WallObs? = nil
        }
        var configured: Configured? = nil
        var observed: Observed? = nil
    }
    let version: String
    let exe: String
    let home: String
    let policy: Policy
    let claude: Agent
    let cursor: Agent
    let codex: Agent?
    let chrome: Agent?
    let audit: Audit
    var walls: Walls? = nil
}

/// Output of `kai policy show --json`.
struct PolicyInfo: Decodable, Equatable {
    struct Term: Decodable, Equatable, Hashable {
        let action: String
        let replacement: String?
        let text: String
    }
    struct Rule: Decodable, Equatable, Hashable {
        let name: String
        let action: String
        let replacement: String?
        let pattern: String
    }
    /// An exception the user made from the Activity page (or the policy file).
    struct Exempt: Decodable, Equatable, Hashable {
        let rule: String
        let pattern: String
    }
    let file: String
    let exists: Bool
    let ok: Bool
    let error: String
    let switches: [String: String]
    let protect: [String]
    let allow: [String]
    let egressAllow: [String]?
    var channels: [String]? = nil   // spec §4: "<agent>/<channel>" lines
    let terms: [Term]
    let rules: [Rule]
    let exempt: [Exempt]? // older kai CLIs don't report exceptions
}

/// Output of `kai report <id> --json`.
struct ReportInfo: Decodable {
    let path: String
    let issueUrl: String
}

struct CommandResult {
    let code: Int32
    let out: String
    let err: String
    var ok: Bool { code == 0 }
    /// The most useful line to show a person when a command fails.
    var message: String {
        let text = err.isEmpty ? out : err
        return text.split(separator: "\n").first.map(String.init) ?? "exit code \(code)"
    }
}

enum KaiCLI {
    /// The `kai` binary to drive: the copy inside the app bundle, built from
    /// the same commit, so the app never reads output from a different CLI
    /// version (a separately installed `kai` drifted from the app once). KAI_BIN
    /// overrides; an installed CLI is used only when the bundle has none.
    static let executable: URL? = {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["KAI_BIN"], !env.isEmpty {
            candidates.append(env)
        }
        if let bundled = Bundle.main.url(forResource: "kai", withExtension: nil) {
            candidates.append(bundled.path)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [
            "/opt/homebrew/bin/kai",
            "/usr/local/bin/kai",
            "\(home)/.local/bin/kai",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }()

    static func run(_ args: [String]) async -> CommandResult {
        guard let exe = executable else {
            return CommandResult(code: 127, out: "", err: "kai command-line tool not found")
        }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                return CommandResult(code: 126, out: "", err: error.localizedDescription)
            }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return CommandResult(code: p.terminationStatus,
                                 out: String(decoding: o, as: UTF8.self),
                                 err: String(decoding: e, as: UTF8.self))
        }.value
    }

    static func decode<T: Decodable>(_ type: T.Type, _ args: [String]) async -> T? {
        let r = await run(args)
        guard r.ok else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(T.self, from: Data(r.out.utf8))
    }
}
