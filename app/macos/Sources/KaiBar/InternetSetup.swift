// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.4.1: the guided step for turning on Internet watching (Settings →
// Internet, and from the popover). macOS asks the user twice: once to allow
// Kai's system extension in System Settings, then "Kai would like to filter
// network content". This view says where to go before each step and flips
// to On by itself (it polls every 2 seconds while visible).
//
// Watch only: nothing here changes what the Network Wall enforces.
import SwiftUI

struct InternetSetupStep: View {
    @EnvironmentObject var wall: NetworkWall
    /// Compact: the popover's one-row form.
    var compact = false

    static let mdmDocs = "https://github.com/sameehj/kai/blob/master/docs/internet-mdm.md"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch wall.state {
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking Internet watching…") }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            case .off:
                Text("Kai can list the destinations agents connect to. It watches connections; it doesn't read "
                     + "traffic, and nothing is blocked.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Turn on Internet watching") { wall.turnOn() }.buttonStyle(LimeButtonStyle())
                ahead
            case .activating:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking macOS to load Kai's extension…") }
                    .font(.system(size: 12))
                ahead
            case .needsApproval:
                Label("macOS needs your OK", systemImage: "hand.raised").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                steps
                diagram
                HStack(spacing: 8) {
                    Button("Open System Settings") { NetworkWall.openApprovalSettings() }.buttonStyle(LimeButtonStyle())
                    Button("Try again") { wall.turnOn() }.buttonStyle(GhostButtonStyle())
                }
            case .allowFilter:
                Label("macOS is asking to allow filtering", systemImage: "network.badge.shield.half.filled")
                    .font(.system(size: 13, weight: .semibold))
                Text("Click Allow in the macOS alert. Kai watches connections; it doesn't read traffic.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            case .on:
                Label("Internet watching is on (Watch only).", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.teal)
            case .failed(let why):
                Label("Internet watching isn't on", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                Text(why.sentenceEnded).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { wall.turnOn() }.buttonStyle(LimeButtonStyle())
            }
            if !compact && wall.state != .on {
                HStack(spacing: 4) {
                    Text("Managed Macs can pre-approve Kai with an MDM profile.")
                    if let u = URL(string: Self.mdmDocs) { Link("How", destination: u) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .task {
            // Flip to On by itself once macOS has approved (every 2 s while shown).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if wall.state != .on { wall.refresh() }
            }
        }
    }

    /// Said before macOS shows its alert.
    private var ahead: some View {
        Text("macOS will ask you twice: allow Kai's system extension in System Settings, then allow filtering. "
             + "Click Allow. Kai watches connections; it doesn't read traffic.")
            .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var steps: some View {
        let new = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
        return VStack(alignment: .leading, spacing: 4) {
            Text("1. Click Open System Settings.")
            Text(new ? "2. Go to General → Login Items & Extensions → Network Extensions and turn Kai on. "
                       + "(Or, under Privacy & Security, find “System software from Kai was blocked” and click Allow.)"
                     : "2. Under Privacy & Security, find “System software from Kai was blocked” and click Allow.")
            Text("3. Come back here. This turns to On by itself.")
        }
        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    /// A small SF Symbols picture of the path (not a screenshot).
    private var diagram: some View {
        let new = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
        let path: [(String, String)] = new
            ? [("gearshape", "System Settings"), ("gearshape.2", "General"),
               ("puzzlepiece.extension", "Login Items & Extensions"), ("network", "Network Extensions"),
               ("togglepower", "Kai: on")]
            : [("gearshape", "System Settings"), ("hand.raised", "Privacy & Security"),
               ("exclamationmark.shield", "System software from Kai was blocked"), ("checkmark.circle", "Allow")]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                    Label(p.1, systemImage: p.0).font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityLabel(path.map(\.1).joined(separator: ", then "))
    }
}

/// The popover's one row when Internet watching isn't on; opens the step.
struct InternetNeedsYouRow: View {
    @EnvironmentObject var wall: NetworkWall
    let open: () -> Void
    var body: some View {
        if wall.state != .on && wall.state != .checking {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "network").foregroundStyle(wall.state == .off ? Theme.muted : Theme.amber)
                    Text(text).font(.system(size: 12)).foregroundStyle(wall.state == .off ? Theme.soft : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    private var text: String {
        switch wall.state {
        case .needsApproval: return "Internet watching needs your OK in System Settings"
        case .allowFilter: return "macOS is asking to allow filtering: click Allow"
        case .failed: return "Internet watching didn't turn on · Try again"
        case .activating: return "Turning on Internet watching…"
        default: return "Internet watching is off · Set it up"
        }
    }
}
