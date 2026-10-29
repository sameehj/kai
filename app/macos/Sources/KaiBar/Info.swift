// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Release batch 12: an ⓘ next to section headings and status words, opening at
// most two short sentences. The copy is fixed here, in one place.
import SwiftUI

enum InfoText {
    static let workingNow = "Did something in the last 15 minutes, or is running a command now."
    static let idle = "Still open, but nothing for 15 minutes or more."
    static let ended = "Closed. Permissions for this session ended with it."
    static let filesInternet = "Kai checks this agent's file access and connections."
    static let internetOnly = "Kai checks this agent's connections. Files protection is off."
    static let watch = "Kai shows what would be blocked, but blocks nothing."
    static let protect = "Kai stops anything you haven't allowed."
    static let thisSession = "Until this agent session ends."
    static let oneHour = "For one hour, even if the session ends sooner."
    static let always = "Until you remove it. Needs Touch ID."
    static let askedRecently = "Sites this agent tried that you haven't decided on."
    static let secretsKept = "Secrets Kai removed or stopped before they were sent."
    static let actionsStopped = "Actions Kai stopped before they ran."
    static let chats = "AI chat sites the Kai extension is checking in Chrome."

    /// The ⓘ for a session's coverage word, if there is one.
    static func coverage(_ short: String) -> String? {
        switch short {
        case "Files + Internet": return filesInternet
        case "Internet only": return internetOnly
        default: return nil
        }
    }
}

struct InfoButton: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More about this")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(width: 240)
        }
    }
}

/// A heading with its ⓘ: "WORKING NOW ⓘ".
struct InfoHeading: View {
    let title: String
    let info: String
    var body: some View {
        HStack(spacing: 4) { CapsLabel(title); InfoButton(text: info) }
    }
}

/// Release batch 13: the app is a preview too.
struct PreviewBadge: View {
    var body: some View {
        Text("Preview").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(Theme.border))
            .help("Kai Preview. Some protections come in a later release.")
    }
}
