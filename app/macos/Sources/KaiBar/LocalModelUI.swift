// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The local model's wiring: which model, the one download in progress, and
// the phraser registered at launch. 0.5: the controls live in one place,
// ModelChooser (the chat's model chip, the Ask header and Settings → Ask Kai),
// which shows the consent line before any download. Never bundled in the
// package.
import SwiftUI

enum LocalModelChoice {
    static var current: LocalModel {
        let id = UserDefaults.standard.string(forKey: "askLocalModel") ?? ""
        return ModelStore.catalog.first { $0.id == id } ?? ModelStore.defaultModel
    }
    /// One phraser per model, kept: the model loads once, not per question.
    private static var cached: LlamaPhraser?
    private static var cachedID: String?
    /// Wire the local phraser in (AskKai.swift's Phrasers.local). Called at
    /// launch (AppDelegate.applicationDidFinishLaunching), not when Settings opens.
    static func register() {
        Phrasers.local = {
            let m = current
            if cachedID != m.id { cached = LlamaPhraser(model: m); cachedID = m.id }
            return cached
        }
        Phrasers.localInstalled = { ModelStore.shared.isInstalled(current) }
        Phrasers.localName = { current.name.replacingOccurrences(of: " (Q4_K_M)", with: "") }
        registered = true
    }
    private(set) static var registered = false
}

/// The one download in progress (every model control shows the same one).
@MainActor
final class ModelDownloads: ObservableObject {
    static let shared = ModelDownloads()
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var tick = 0

    func start(_ m: LocalModel, onProgress: (@MainActor (Double) -> Void)? = nil,
               then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard progress == nil else { return }
        error = nil
        progress = 0
        Task {
            var ok = false
            do {
                _ = try await ModelStore.shared.download(m) { p in
                    Task { @MainActor in
                        guard ModelDownloads.shared.progress != nil else { return }
                        ModelDownloads.shared.progress = p
                        onProgress?(p)
                    }
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
