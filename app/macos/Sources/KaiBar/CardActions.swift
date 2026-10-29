// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// The buttons under a decision card (popover, Activity, Agent Control).
// Labels are actions only ("Allow 1 hour"); the card's title already names the
// agent and the site. One row when every button fits at its full width,
// otherwise one full-width button per line. A label never truncates: a row is
// used only when each button gets its ideal width, and a stacked label wraps.
import SwiftUI

struct CardAction: Identifiable {
    let title: String
    var info: String? = nil      // an ⓘ next to the button
    var primary = false          // Return triggers it
    var enabled = true
    var help = ""
    let action: () -> Void
    var id: String { title }
}

struct CardActions: View {
    let actions: [CardAction]
    var more: [CardAction] = []
    var moreInfo: String? = nil
    var why: (label: String, toggle: () -> Void)? = nil
    /// Tests: every placed button's ideal and given width.
    var onPlace: (([(ideal: CGFloat, given: CGFloat)]) -> Void)? = nil

    var body: some View {
        RowOrStack(spacing: 8, onPlace: onPlace) {
            ForEach(actions) { a in item(a) }
            if !more.isEmpty { moreMenu }
            if let w = why {
                Button(w.label, action: w.toggle).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize()
                    .layoutValue(key: TextLink.self, value: true)
            }
        }
    }

    @ViewBuilder private func item(_ a: CardAction) -> some View {
        HStack(spacing: 4) {
            let b = Button(action: a.action) {
                Text(a.title).lineLimit(nil).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle()).disabled(!a.enabled).help(a.help)
            if a.primary { b.keyboardShortcut(.defaultAction) } else { b }
            if let t = a.info { InfoButton(text: t) }
        }
    }

    private var moreMenu: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(more) { m in Button(m.title, action: m.action).disabled(!m.enabled).help(m.help) }
            } label: {
                Text("More ▾").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 12).frame(minHeight: 32).frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border))
            if let t = moreInfo { InfoButton(text: t) }
        }
    }
}

/// A text link ("Why?") keeps its own width when stacked.
private struct TextLink: LayoutValueKey { static let defaultValue = false }

/// One row if every subview fits at its ideal width; else one per line, full
/// width (text links at their own width).
struct RowOrStack: Layout {
    var spacing: CGFloat = 8
    var onPlace: (([(ideal: CGFloat, given: CGFloat)]) -> Void)? = nil

    private func ideals(_ subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

    static func fitsRow(_ widths: [CGFloat], spacing: CGFloat, in width: CGFloat) -> Bool {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) <= width + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = ideals(subviews)
        let rowWidth = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: rowWidth, height: sizes.map(\.height).max() ?? 0)
        }
        if RowOrStack.fitsRow(sizes.map(\.width), spacing: spacing, in: width) {
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: h.reduce(0, +) + spacing * CGFloat(max(0, h.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = ideals(subviews)
        var placed: [(ideal: CGFloat, given: CGFloat)] = []
        if RowOrStack.fitsRow(sizes.map(\.width), spacing: spacing, in: bounds.width) {
            var x = bounds.minX
            let rowH = sizes.map(\.height).max() ?? 0
            for (s, sz) in zip(subviews, sizes) {
                s.place(at: CGPoint(x: x, y: bounds.minY + (rowH - sz.height) / 2), proposal: ProposedViewSize(sz))
                placed.append((sz.width, sz.width))
                x += sz.width + spacing
            }
        } else {
            var y = bounds.minY
            for (s, sz) in zip(subviews, sizes) {
                let link = s[TextLink.self]
                let w = link ? min(sz.width, bounds.width) : bounds.width
                let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: w, height: h))
                // stacked text wraps, so the given width only has to hold its longest word
                placed.append((min(sz.width, bounds.width), w))
                y += h + spacing
            }
        }
        onPlace?(placed)
    }
}
