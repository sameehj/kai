// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
// Decision-card buttons never truncate (popover bug: "Allow Clau…", "Keep
// bloc…"). Renders the card actions at the popover's width with the longest
// agent and host names, checks every button gets its full width (or wraps when
// stacked), and writes the snapshot. Compiled with Theme.swift, Info.swift and
// CardActions.swift (tests/app/run_app_tests.sh).
import AppKit
import SwiftUI

var fails = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { fails += 1 }
}

let popoverWidth: CGFloat = 360, cardInner: CGFloat = 360 - 2 * 16 - 2 * 10   // popover and card padding
let agent = "Claude Code", host = "artifacts-eu-west-1.internal-registry.example-enterprise.com"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()

struct TestCard: View {
    let actions: [CardAction]
    var more: [CardAction] = []
    let onPlace: ([(ideal: CGFloat, given: CGFloat)]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(agent) · session “kai” wanted to connect to \(host).")
                .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Kai blocked it because it isn't on your list.").font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            CardActions(actions: actions, more: more, moreInfo: "i", why: ("Why?", {}), onPlace: onPlace)
        }
        .padding(10).frame(width: cardInner + 20, alignment: .leading)
        .background(Color(white: 0.12))
    }
}

@MainActor func render(_ name: String, _ actions: [CardAction], more: [CardAction] = [], width: CGFloat) -> [(ideal: CGFloat, given: CGFloat)] {
    var placed: [(ideal: CGFloat, given: CGFloat)] = []
    let v = TestCard(actions: actions, more: more) { placed = $0 }.environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: v)
    let size = NSSize(width: width, height: max(80, host.fittingSize.height))
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
    }
    return placed
}

let popover = [CardAction(title: "Allow this session", info: "i", primary: true) {},
               CardAction(title: "Allow 1 hour", info: "i") {},
               CardAction(title: "Keep blocked") {}]
let more = [CardAction(title: "Always allow (Touch ID)") {}, CardAction(title: "Allow 1 day") {}]
let touch = [CardAction(title: "Allow 15 minutes (Touch ID)", primary: true) {}, CardAction(title: "Keep blocked") {}]

MainActor.assumeIsolated {
    print("decision cards never truncate (popover width \(Int(popoverWidth)))")
    for (name, acts, m) in [("card-popover", popover, more), ("card-touchid", touch, [])] {
        let placed = render(name, acts, more: m, width: cardInner + 20)
        check(!placed.isEmpty, "\(name): laid out")
        check(placed.allSatisfy { $0.given + 0.5 >= $0.ideal }, "\(name): every button gets its full width or wraps")
    }
    // wide (Activity): one row
    var row: [(ideal: CGFloat, given: CGFloat)] = []
    let v = CardActions(actions: popover, more: more, why: ("Why?", {})) { row = $0 }
    let h = NSHostingView(rootView: v.frame(width: 900))
    h.frame = NSRect(x: 0, y: 0, width: 900, height: 60); h.layoutSubtreeIfNeeded()
    check(!row.isEmpty && row.allSatisfy { $0.given == $0.ideal }, "Activity width: one row, every label whole")
    check(!RowOrStack.fitsRow([150, 120, 120, 90, 40], spacing: 8, in: cardInner), "popover width: these labels stack")
    check(RowOrStack.fitsRow([100, 100], spacing: 8, in: 208), "exact fit stays on one row")
}
for label in ["Allow this session", "Allow 1 hour", "Keep blocked", "More ▾"] {
    check(!label.contains(agent) && !label.contains("Claude"), "action-only label: \(label)")
}
print(fails == 0 ? "card tests: all passed" : "card tests: \(fails) failed")
exit(fails == 0 ? 0 : 1)
