// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: real agent logos everywhere (Now cards, Activity headers, Settings →
// Agents, the popover, the Ask context chip). AgentIconSource picks the
// source; this caches the image and refreshes it when Kai becomes active (an
// app installed or updated meanwhile).
import AppKit
import SwiftUI

@MainActor
enum AgentIcon {
    private static var cache: [String: NSImage] = [:]
    private static var observer: NSObjectProtocol?

    static func image(for agent: String) -> NSImage {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { _ in
                Task { @MainActor in cache.removeAll() }
            }
        }
        if let i = cache[agent] { return i }
        let img: NSImage
        switch AgentIconSource.resolve(agent, installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        case .app(let url): img = NSWorkspace.shared.icon(forFile: url.path)
        case .bundled(let name): img = NSImage(named: name) ?? NSImage(named: "KaiLogo") ?? NSImage()
        }
        cache[agent] = img
        return img
    }
    static func image(for agent: Agent) -> NSImage { image(for: agent.rawValue) }

    /// The bundled mark's asset name when the agent's own app isn't installed.
    private static var names: [String: String?] = [:]
    static func bundledName(for agent: String) -> String? {
        if cache[agent] == nil { names[agent] = nil }   // the image cache was refreshed: look again
        _ = image(for: agent)                           // installs the refresh observer
        if let n = names[agent] { return n }
        var n: String? = nil
        if case .bundled(let b) = AgentIconSource.resolve(agent, installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
            n = b
        }
        names[agent] = n
        return n
    }
}

/// The logo in a rounded square: 28 pt on Now cards, 16 pt in rows.
struct AgentLogo: View {
    let agent: String
    var size: CGFloat = 16
    var body: some View {
        logo
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(size >= 24 ? 3 : 1)
            .frame(width: size, height: size)
            .background(Theme.raised.opacity(size >= 24 ? 1 : 0), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityLabel(ActivityFeed.agentTitle(agent))
    }

    /// The app's own icon, else the bundled mark from the asset catalog,
    /// which picks the light or dark variant for the current appearance.
    @MainActor private var logo: Image {
        if let n = AgentIcon.bundledName(for: agent) { return Image(n) }
        return Image(nsImage: AgentIcon.image(for: agent))
    }
}
