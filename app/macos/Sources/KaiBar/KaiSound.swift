// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
import AppKit

enum KaiSound {
    private static var current: NSSound?

    enum Cue: String, CaseIterable {
        case signature = "kai-signature"
        case allowed = "kai-allowed"
        case blocked = "kai-blocked"
        case approvalNeeded = "kai-approval-needed"

        var fileName: String { rawValue + ".wav" }
        var title: String {
            switch self {
            case .signature: return "Signature"
            case .allowed: return "Granted"
            case .blocked: return "Blocked"
            case .approvalNeeded: return "Approval needed"
            }
        }
    }

    static func play(_ cue: Cue) {
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return }
        current?.stop()
        current = sound
        sound.play()
    }
}
