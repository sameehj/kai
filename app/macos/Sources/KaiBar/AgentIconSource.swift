// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: where an agent's logo comes from, in order: the icon of the agent's
// own installed app, else the official mark bundled in Assets.xcassets
// (sources in THIRD_PARTY_NOTICES.md). Never initials or a text tile.
// Foundation only: compiled into the app tests (AgentIcon.swift draws it).
import Foundation

enum AgentIconSource: Equatable {
    case app(URL)
    case bundled(String)

    /// The installed apps whose icon stands for the agent, most specific first.
    static func bundleIDs(_ agent: String) -> [String] {
        switch agent {
        case "cursor": return ["com.todesktop.230313mzl4w4u92"]            // Cursor.app
        case "claude": return ["com.anthropic.claudefordesktop"]           // the Claude desktop app
        case "codex": return ["com.openai.codex", "com.openai.chat"]       // the Codex app, else ChatGPT
        default: return []
        }
    }

    /// The bundled official mark (Assets.xcassets).
    static func bundledName(_ agent: String) -> String {
        switch agent {
        case "claude": return "AgentClaude"
        case "cursor": return "AgentCursor"
        case "codex": return "AgentOpenAI"
        default: return "KaiLogo"
        }
    }

    /// `installed(bundleID)` is the app's URL when it's installed (NSWorkspace).
    static func resolve(_ agent: String, installed: (String) -> URL?) -> AgentIconSource {
        for id in bundleIDs(agent) { if let u = installed(id) { return .app(u) } }
        return .bundled(bundledName(agent))
    }
}
