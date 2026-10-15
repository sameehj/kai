// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's look: deep ink surfaces with an electric-lime accent (assets/BRAND.md).
// The app is always dark, like the menu-bar panel it lives in.
import SwiftUI

enum Theme {
    static let ink = Color(hex: 0x101114)
    static let sidebar = Color(hex: 0x16171A)
    static let surface = Color(hex: 0x1C1D21)
    static let raised = Color(hex: 0x23252B)
    static let border = Color(hex: 0x2A2C32)
    static let lime = Color(hex: 0xD9FF3F)
    static let coral = Color(hex: 0xFF6B5E)
    static let amber = Color(hex: 0xFFB547)
    static let muted = Color(hex: 0xA7ABB4)
    static let soft = Color(hex: 0xC9CCD3)

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
}

extension Color {
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

/// Lime pill switch matching the design.
struct KaiToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.lime : Theme.raised)
                    .overlay(Capsule().stroke(configuration.isOn ? Color.clear : Theme.border))
                Circle().fill(configuration.isOn ? Theme.ink : Theme.muted)
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

/// Filled lime button ("Add", "Allow").
struct LimeButtonStyle: ButtonStyle {
    var subtle = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .foregroundStyle(subtle ? Theme.lime : Theme.ink)
            .background(subtle ? Theme.lime.opacity(0.10) : Theme.lime,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(subtle ? Color(hex: 0x3A4420) : .clear))
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
            .foregroundStyle(.white)
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
