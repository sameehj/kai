// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: choosing the model in the chat. One controller (ModelChip's state
// machine) behind the chip in the Ask dock, the chip in the Ask page header
// and Settings → Ask Kai. The download starts only from the menu or the
// first-run card, both of which show the consent line next to the button.
import SwiftUI

@MainActor
final class ModelController: ObservableObject {
    static let shared = ModelController()
    @Published private(set) var state: ModelChip.State = .none
    @Published private(set) var error: String?

    var localInstalled: Bool { ModelStore.shared.isInstalled(LocalModelChoice.current) }
    var appleAvailable: Bool { AppleIntelligencePhraser().isAvailable }
    var appleReason: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "Unavailable: turn on Apple Intelligence in System Settings"
            : "Unavailable: needs macOS 26 with Apple Intelligence"
    }
    var label: String { ModelChip.label(state) }
    var options: [ModelChip.Option] {
        ModelChip.options(state, localInstalled: localInstalled, appleAvailable: appleAvailable, appleReason: appleReason)
    }

    init() { sync() }

    /// The state from what's chosen and on disk (a download in progress wins).
    func sync() {
        if case .failed = state, ModelDownloads.shared.progress == nil { return }
        state = ModelChip.state(chosen: AskController.shared.kind, localInstalled: localInstalled,
                                appleAvailable: appleAvailable, progress: ModelDownloads.shared.progress)
    }

    private func send(_ e: ModelChip.Event) {
        state = ModelChip.reduce(state, e, localInstalled: localInstalled, appleAvailable: appleAvailable)
    }

    func choose(_ k: PhraserKind) {
        if k == .local && !localInstalled { download(); return }
        send(.choose(k))
        AskController.shared.modelRaw = k.rawValue
    }

    /// Downloads the default local model (the consent line is next to the button
    /// that calls this), then switches to it and says so in the chat.
    func download() {
        guard ModelDownloads.shared.progress == nil else { return }
        error = nil
        send(.startDownload)
        ModelDownloads.shared.start(LocalModelChoice.current, onProgress: { [weak self] p in
            self?.send(.progress(p))
        }) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.send(.verified)
                AskController.shared.modelRaw = PhraserKind.local.rawValue
                self.state = ModelChip.settle(self.state)
                AskController.shared.note(ModelChip.nowAnswering("Qwen 0.8B"))
            } else {
                self.error = ModelDownloads.shared.error
                self.send(.failed(ModelDownloads.shared.error ?? "The download didn't finish."))
            }
        }
    }

    func delete() {
        try? ModelStore.shared.delete(LocalModelChoice.current)
        ModelDownloads.shared.changed()
        if AskController.shared.kind == .local { AskController.shared.modelRaw = PhraserKind.templates.rawValue }
        send(.delete)
        if case .active(.local) = state { state = .none }
    }
}

/// The chip ("Templates ▾") and its menu; or, in Settings, the same menu
/// contents laid out on the page.
struct ModelChooser: View {
    enum Style { case chip, settings }
    var style: Style = .chip
    @ObservedObject private var c = ModelController.shared
    @ObservedObject private var downloads = ModelDownloads.shared
    @ObservedObject private var ask = AskController.shared
    @State private var open = false

    var body: some View {
        switch style {
        case .chip:
            Button { c.sync(); open.toggle() } label: {
                Text(c.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.soft)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.raised.opacity(0.8), in: Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Choose how Ask Kai words its answers")
            .popover(isPresented: $open, arrowEdge: .top) { menu.padding(14).frame(width: 360) }
        case .settings:
            menu.onAppear { c.sync() }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style == .chip {
                Text("Answers come from Kai's records. A model only rewords them.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(c.options, id: \.title) { o in option(o) }
            if let e = c.error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func option(_ o: ModelChip.Option) -> some View {
        let inUse = o.status == "In use"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: inUse ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                    .foregroundStyle(inUse ? Theme.teal : Theme.muted)
                Text(o.title).font(.system(size: 13, weight: .semibold))
                if !o.size.isEmpty { Text("· " + o.size).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                Spacer()
                actions(o)
            }
            Text(o.detail + (o.status.isEmpty || inUse ? "" : " · " + o.status))
                .font(.system(size: 11.5)).foregroundStyle(o.available ? Theme.muted : Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
            if o.kind == .local, !c.localInstalled, downloads.progress == nil {
                Text(ModelChip.consentLine).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if o.kind == .local, let p = downloads.progress { ProgressView(value: p).frame(maxWidth: 260) }
        }
        .padding(10)
        .background(inUse ? Theme.teal.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border))
    }

    @ViewBuilder private func actions(_ o: ModelChip.Option) -> some View {
        switch o.kind {
        case .local:
            if downloads.progress != nil {
                Text("\(Int((downloads.progress ?? 0) * 100))%").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            } else if c.localInstalled {
                if o.status != "In use" { Button("Use") { c.choose(.local) }.buttonStyle(LimeButtonStyle(subtle: true)) }
                Button("Delete") { c.delete() }.buttonStyle(GhostButtonStyle())
            } else {
                Button("Download") { c.download() }.buttonStyle(LimeButtonStyle(subtle: true))
            }
        default:
            if o.status != "In use" {
                Button("Use") { c.choose(o.kind) }.buttonStyle(LimeButtonStyle(subtle: true)).disabled(!o.available)
            }
        }
    }
}

/// The first-run card in the chat: once, dismissible, when no model is set.
struct ModelFirstRunCard: View {
    @ObservedObject private var c = ModelController.shared
    @ObservedObject private var downloads = ModelDownloads.shared
    @AppStorage("askModelCardDismissed") private var dismissed = false
    var body: some View {
        if !dismissed && c.state == .none && downloads.progress == nil && !c.appleAvailable {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ModelChip.firstRunLine).font(.system(size: 12.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ModelChip.consentLine).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Download") { dismissed = true; c.download() }.buttonStyle(LimeButtonStyle(subtle: true))
                        Button("Not now") { dismissed = true }.buttonStyle(GhostButtonStyle())
                    }
                }
                Spacer(minLength: 0)
                Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Dismiss")
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border))
        }
    }
}
