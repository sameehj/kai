// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// llama.cpp's prebuilt xcframework (MIT), pinned to one release by URL and
// checksum. SwiftPM fetches it at build time; it is linked into Kai.app for
// the optional local phraser (LlamaPhraser.swift). No model is bundled.
//
// To bump: pick a release at least two weeks old that ships
// llama-<tag>-xcframework.zip, then `swift package compute-checksum` the zip.
import PackageDescription

let package = Package(
    name: "LlamaBinary",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LlamaBinary", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12182/llama-b12182-xcframework.zip",
            checksum: "5c9e766aa026046c04d80d27f187cb76317be00089daebb94aa52768f090bd8b"
        ),
    ]
)
