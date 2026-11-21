// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's look, 0.4 (assets/BRAND.md): neutral greys that follow light and dark
// mode; teal #25C7B8 for primary actions and selection; purple #7659E8 for the
// brand accent only; amber = needs attention; red = Kai is off, nothing else.
// Brand colours never mean "protected".
import AppKit
import SwiftUI

enum Theme {
    static let ink = Color.adaptive(light: 0xFBFBFD, dark: 0x111218)
    static let sidebar = Color.adaptive(light: 0xF2F3F7, dark: 0x161821)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1A1C25)
    static let raised = Color.adaptive(light: 0xEEEFF6, dark: 0x262935)
    static let border = Color.adaptive(light: 0xE2E4EB, dark: 0x30323E)
    /// Primary text: near-black in light mode, near-white in dark.
    static let text = Color.adaptive(light: 0x242532, dark: 0xF4F3F7)
    /// Primary actions and selection.
    static let teal = Color(hex: 0x25C7B8)
    /// Text on a teal fill.
    static let onTeal = Color(hex: 0x0B1F1D)
    /// Brand accent only (logo, Ask Kai label). Never a status.
    static let purple = Color(hex: 0x7659E8)
    /// Kept for older views: the action colour (was lime before 0.4).
    static let lime = teal
    static let coral = Color.adaptive(light: 0xB64F59, dark: 0xEA888B)
    static let amber = Color.adaptive(light: 0xAC752A, dark: 0xE4AE66)
    /// Neutral information: a routine stop (red is only for Kai itself off).
    static let blue = Color.adaptive(light: 0x4B6FA8, dark: 0x7DB4FF)
    static let muted = Color.adaptive(light: 0x737787, dark: 0x989BA9)
    static let soft = Color.adaptive(light: 0x4A4D5C, dark: 0xC9CCD3)

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
}

extension Color {
    /// A colour that follows the window's light or dark appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark } ?? false
            let h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Rounded card: the basic building block of every screen.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var stroke: Color = Theme.border
    var fill: Color = Theme.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(stroke, lineWidth: 1))
    }
}

/// Small spaced caps heading ("PROTECTION", "RECENT").
struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(1).foregroundStyle(Theme.muted)
    }
}

/// Teal pill switch.
struct KaiToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.lime : Theme.raised)
                    .overlay(Capsule().stroke(configuration.isOn ? Color.clear : Theme.border))
                Circle().fill(configuration.isOn ? Color.white : Theme.muted)
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
            .frame(width: 44, height: 26)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// Filled teal button ("Add", "Allow"): the primary action.
struct LimeButtonStyle: ButtonStyle {
    var subtle = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .foregroundStyle(subtle ? Theme.lime : Theme.onTeal)
            .background(subtle ? Theme.lime.opacity(0.10) : Theme.lime,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(subtle ? Theme.lime.opacity(0.35) : .clear))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Outlined quiet button.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(Theme.text)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Text field styled for the dark surfaces.
struct KaiField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border))
            .onSubmit(onSubmit)
    }
}
