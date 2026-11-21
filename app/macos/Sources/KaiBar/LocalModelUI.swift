// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Settings → General → Ask Kai → Local model: which model, its status, and
// the download, which happens only after a consent sheet that shows its size.
// Never bundled in the package.
import SwiftUI

enum LocalModelChoice {
    static var current: LocalModel {
        let id = UserDefaults.standard.string(forKey: "askLocalModel") ?? ""
        return ModelStore.catalog.first { $0.id == id } ?? ModelStore.defaultModel
    }
    /// Wire the local phraser in (AskKai.swift's Phrasers.local).
    static func register() {
        Phrasers.local = { LlamaPhraser(model: current) }
    }
}

struct LocalModelSettings: View {
    @AppStorage("askLocalModel") private var modelID = ModelStore.defaultModel.id
    @State private var consent: LocalModel?
    @State private var progress: Double?
    @State private var error: String?
    @State private var tick = 0

    private var model: LocalModel { ModelStore.catalog.first { $0.id == modelID } ?? ModelStore.defaultModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Local model", selection: $modelID) {
                ForEach(ModelStore.catalog) { m in Text("\(m.name) · \(m.sizeText) · \(m.license)").tag(m.id) }
            }
            .frame(maxWidth: 460)
            let installed = ModelStore.shared.isInstalled(model)
            HStack(spacing: 10) {
                if let p = progress {
                    ProgressView(value: p).frame(width: 200)
                    Text("\(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else if installed {
                    Label("Downloaded and verified", systemImage: "checkmark.circle").font(.system(size: 12))
                    Button("Delete") { try? ModelStore.shared.delete(model); tick += 1 }
                } else {
                    Text("Not downloaded").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("Download…") { consent = model }
                }
            }
            .id(tick)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber) }
            Text("Runs on this Mac with llama.cpp. Kai uses templates until a model is downloaded, and whenever "
                 + "the model fails.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .sheet(item: $consent) { m in
            VStack(alignment: .leading, spacing: 12) {
                Text("Download \(m.name)?").font(.system(size: 17, weight: .semibold))
                Text("Kai will download \(m.sizeText) from Hugging Face (\(m.repo)) to "
                     + "~/Library/Application Support/Kai/models/ and check it against a pinned SHA-256 before "
                     + "using it. License: \(m.license). Nothing about your activity is sent; the model runs on "
                     + "this Mac.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { consent = nil }.keyboardShortcut(.cancelAction)
                    Button("Download \(m.sizeText)") { consent = nil; start(m) }.buttonStyle(LimeButtonStyle())
                }
            }
            .padding(24).frame(width: 460)
        }
    }

    private func start(_ m: LocalModel) {
        error = nil
        progress = 0
        Task {
            do {
                _ = try await ModelStore.shared.download(m) { p in
                    Task { @MainActor in progress = p }
                }
            } catch {
                self.error = "The download didn't finish or didn't match its checksum, so Kai deleted it. Try again."
            }
            progress = nil
            tick += 1
        }
    }
}
