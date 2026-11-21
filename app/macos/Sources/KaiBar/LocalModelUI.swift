// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Settings → General → Ask Kai → Local model: which model, its status, and
// the download, which happens only after a consent sheet that shows its size.
// Never bundled in the package. 0.4.1: the same consent sheet opens from the
// Ask Kai page ("Get the local model"); one download at a time, shared.
import SwiftUI

enum LocalModelChoice {
    static var current: LocalModel {
        let id = UserDefaults.standard.string(forKey: "askLocalModel") ?? ""
        return ModelStore.catalog.first { $0.id == id } ?? ModelStore.defaultModel
    }
    /// One phraser per model, kept: the model loads once, not per question.
    private static var cached: LlamaPhraser?
    private static var cachedID: String?
    /// Wire the local phraser in (AskKai.swift's Phrasers.local). Called at launch.
    static func register() {
        Phrasers.local = {
            let m = current
            if cachedID != m.id { cached = LlamaPhraser(model: m); cachedID = m.id }
            return cached
        }
        Phrasers.localInstalled = { ModelStore.shared.isInstalled(current) }
        Phrasers.localName = { current.name.replacingOccurrences(of: " (Q4_K_M)", with: "") }
    }
}

/// The one download in progress (Settings and the Ask page show the same one).
@MainActor
final class ModelDownloads: ObservableObject {
    static let shared = ModelDownloads()
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var tick = 0

    func start(_ m: LocalModel, then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard progress == nil else { return }
        error = nil
        progress = 0
        Task {
            var ok = false
            do {
                _ = try await ModelStore.shared.download(m) { p in
                    Task { @MainActor in ModelDownloads.shared.progress = p }
                }
                ok = true
            } catch {
                self.error = "The download didn't finish or didn't match its checksum, so Kai deleted it. Try again."
            }
            progress = nil
            tick += 1
            done(ok)
        }
    }
    func changed() { tick += 1 }
}

/// Consent before any download: size, source, where it goes, license.
struct ModelConsentSheet: View {
    let model: LocalModel
    let onCancel: () -> Void
    let onDownload: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download \(model.name)?").font(.system(size: 17, weight: .semibold))
            Text("Kai will download \(model.sizeText) from Hugging Face (\(model.repo)) to "
                 + "~/Library/Application Support/Kai/models/ and check it against a pinned SHA-256 before "
                 + "using it. License: \(model.license). Nothing about your activity is sent; the model runs on "
                 + "this Mac. It only picks what kind of question you asked and rewords Kai's answer; it never "
                 + "sees your records or changes anything.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Download \(model.sizeText)", action: onDownload).buttonStyle(LimeButtonStyle())
            }
        }
        .padding(24).frame(width: 460)
    }
}

struct LocalModelSettings: View {
    @AppStorage("askLocalModel") private var modelID = ModelStore.defaultModel.id
    @ObservedObject private var downloads = ModelDownloads.shared
    @State private var consent: LocalModel?

    private var model: LocalModel { ModelStore.catalog.first { $0.id == modelID } ?? ModelStore.defaultModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Local model", selection: $modelID) {
                ForEach(ModelStore.catalog) { m in Text("\(m.name) · \(m.sizeText) · \(m.license)").tag(m.id) }
            }
            .frame(maxWidth: 460)
            let installed = ModelStore.shared.isInstalled(model)
            HStack(spacing: 10) {
                if let p = downloads.progress {
                    ProgressView(value: p).frame(width: 200)
                    Text("\(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else if installed {
                    Label("Downloaded and verified", systemImage: "checkmark.circle").font(.system(size: 12))
                    Button("Delete") { try? ModelStore.shared.delete(model); downloads.changed() }
                } else {
                    Text("Not downloaded").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Download…") { consent = model }
                }
            }
            .id(downloads.tick)
            if let error = downloads.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber) }
            Text("Runs on this Mac with llama.cpp. Kai uses templates until a model is downloaded, and whenever "
                 + "the model fails.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .sheet(item: $consent) { m in
            ModelConsentSheet(model: m, onCancel: { consent = nil },
                              onDownload: { consent = nil; downloads.start(m) })
        }
    }
}
