// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5: the model chip in the Ask dock and the Ask page header ("Templates ▾",
// "Qwen 0.8B ▾", "Apple Intelligence ▾", "Qwen 34%" while downloading). One
// state machine for every place that shows it (dock, Ask header, Settings →
// Ask Kai):
//
//   none (templates) ─download→ downloading(p) ─verified→ verified ─→ active(local)
//         ↑                         │ failed → failed(why)
//         └──────── delete ─────────┴──────────────────────────────────┘
//
// Nothing downloads without the consent line being shown first (the menu
// shows it next to Download). Foundation only: compiled into the app tests.
import Foundation

enum ModelChip {
    enum State: Equatable {
        case none                      // templates: Kai's own wording
        case downloading(Double)       // 0...1
        case verified                  // the file matched its SHA-256; switching to it
        case active(PhraserKind)       // answering with this model
        case failed(String)
    }
    enum Event: Equatable {
        case startDownload, progress(Double), verified, failed(String), choose(PhraserKind), delete
    }

    static let consentLine = "Downloads ≈500 MB from Hugging Face (pinned version, checked with SHA-256). "
        + "Nothing you ask is sent anywhere."
    static let firstRunLine = "Better answers, still private: download a small model that runs on this Mac"
    static func nowAnswering(_ name: String) -> String { "Now answering with \(name) on this Mac." }

    /// The next state. `localInstalled`/`appleAvailable` say what can be chosen.
    static func reduce(_ s: State, _ e: Event, localInstalled: Bool, appleAvailable: Bool) -> State {
        switch (s, e) {
        case (.downloading, .startDownload): return s            // one download at a time
        case (_, .startDownload): return .downloading(0)
        case (.downloading, .progress(let p)): return .downloading(min(1, max(0, p)))
        case (.downloading, .verified): return .verified
        case (.downloading, .failed(let why)): return .failed(why)
        case (.verified, .choose(.local)), (.verified, .progress): return .active(.local)
        case (.downloading, .choose): return s                   // finish (or fail) first
        case (_, .choose(.templates)): return .none
        case (_, .choose(.local)): return localInstalled ? .active(.local) : s
        case (_, .choose(.appleIntelligence)): return appleAvailable ? .active(.appleIntelligence) : s
        case (.active(.local), .delete), (.verified, .delete), (.failed, .delete): return .none
        case (_, .delete): return s
        default: return s
        }
    }

    /// After a verified download the chip switches to the model by itself.
    static func settle(_ s: State) -> State { s == .verified ? .active(.local) : s }

    /// The state for what's chosen and what's on disk (at launch, after Settings).
    static func state(chosen: PhraserKind, localInstalled: Bool, appleAvailable: Bool, progress: Double?) -> State {
        if let p = progress { return .downloading(p) }
        switch chosen {
        case .appleIntelligence: return appleAvailable ? .active(.appleIntelligence) : .none
        case .local: return localInstalled ? .active(.local) : .none
        case .templates: return .none
        }
    }

    /// The chip's words.
    static func label(_ s: State) -> String {
        switch s {
        case .none, .failed: return "Templates ▾"
        case .downloading(let p): return "Qwen \(Int((p * 100).rounded(.down)))%"
        case .verified, .active(.local): return "Qwen 0.8B ▾"
        case .active(.appleIntelligence): return "Apple Intelligence ▾"
        case .active(.templates): return "Templates ▾"
        }
    }

    /// The menu's three options, each with its line, size and status.
    struct Option: Equatable {
        var kind: PhraserKind
        var title: String
        var detail: String
        var size: String
        var status: String
        var available: Bool
    }
    static func options(_ s: State, localInstalled: Bool, appleAvailable: Bool, appleReason: String) -> [Option] {
        let active: PhraserKind? = { if case .active(let k) = s { return k }; return s == .none ? .templates : nil }()
        let local: String
        if case .downloading(let p) = s { local = "Downloading \(Int(p * 100))%" }
        else if active == .local { local = "In use" }
        else { local = localInstalled ? "Downloaded" : "Not downloaded" }
        return [
            Option(kind: .appleIntelligence, title: "Apple Intelligence", detail: "Built into macOS 26.", size: "",
                   status: appleAvailable ? (active == .appleIntelligence ? "In use" : "Available") : appleReason,
                   available: appleAvailable),
            Option(kind: .local, title: "Local model · Qwen3.5 0.8B", detail: "Runs on this Mac, no internet after download.",
                   size: "≈500 MB", status: local, available: true),
            Option(kind: .templates, title: "Templates", detail: "Kai's own wording, no model.", size: "",
                   status: active == .templates ? "In use" : "Available", available: true),
        ]
    }
}
