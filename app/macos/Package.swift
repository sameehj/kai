// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai menu-bar app. A thin SwiftUI front end over the `kai` CLI: every read
// goes through `kai status --json` / `kai policy show --json`, every change
// through `kai install|uninstall|policy ...`, so the app and the terminal can
// never disagree. Build the .app bundle with `make app` from the repo root.
import PackageDescription

let package = Package(
    name: "KaiBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "KaiBar", path: "Sources/KaiBar")
    ]
)
