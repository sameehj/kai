// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: where a page name or a kai:// link goes. Settings sub-pages, the
// window's pages, and redirects for names older Kais saved or linked
// ("decisions" and "agents" were window pages until 0.5). Foundation only:
// compiled into the app tests.
import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, agents, ask, rules, files, internet, advanced, uninstall
    var id: String { rawValue }
    /// A page saved or linked by an older Kai ("storage", "network", "decisions", ...).
    init(stored raw: String) {
        switch raw.lowercased() {
        case "storage": self = .files
        case "network": self = .internet
        case "decisions", "exceptions", "checks", "protection": self = .rules
        case "agentcontrol", "agent-control", "agent": self = .agents
        case "askkai", "ask-kai", "model": self = .ask
        case "permissions", "company": self = .advanced
        default: self = SettingsPage(rawValue: raw.lowercased()) ?? .general
        }
    }
    var title: String {
        switch self {
        case .general: return "General"
        case .agents: return "Agents"
        case .ask: return "Ask Kai"
        case .rules: return "Rules"
        case .files: return "Files"
        case .internet: return "Internet"
        case .advanced: return "Advanced"
        case .uninstall: return "Uninstall"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "person.2"
        case .ask: return "bubble.left.and.text.bubble.right"
        case .rules: return "list.bullet.clipboard"
        case .files: return "folder"
        case .internet: return "globe"
        case .advanced: return "slider.horizontal.3"
        case .uninstall: return "trash"
        }
    }
}

/// Where a kai:// link opens.
enum KaiRoute: Equatable {
    case now
    case activity(stopsOnly: Bool)
    case ask
    case settings(SettingsPage)

    /// kai://settings/<page>, kai://now, kai://activity, kai://activity/stops,
    /// kai://ask; old kai://decisions and kai://agents (0.4 pages) redirect.
    static func from(_ url: URL) -> KaiRoute? {
        guard url.scheme == "kai", let host = url.host?.lowercased() else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch host {
        case "settings":
            // A stops link from 0.4's Decisions page lands on Activity → Stops.
            if path == "decisions/stops" { return .activity(stopsOnly: true) }
            return .settings(SettingsPage(stored: path.split(separator: "/").first.map(String.init) ?? ""))
        case "now", "home": return .now
        case "activity": return .activity(stopsOnly: path == "stops")
        case "decisions": return .activity(stopsOnly: true)
        case "agents": return .settings(.agents)
        case "ask", "ask-kai": return .ask
        default: return nil
        }
    }

    /// A window page name an older Kai saved ("agents", "decisions").
    static func fromSavedPage(_ raw: String) -> KaiRoute {
        switch raw {
        case "activity": return .activity(stopsOnly: false)
        case "decisions": return .activity(stopsOnly: true)
        case "agents": return .settings(.agents)
        case "ask": return .ask
        case "settings": return .settings(.general)
        default: return .now
        }
    }
}
