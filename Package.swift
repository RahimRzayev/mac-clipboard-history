// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipboardHistory",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Pinned at 1.15.0: releases from 1.16 on contain #Preview macros, which fail to
        // build with Command Line Tools alone (the previews macro plugin ships with Xcode).
        // Safe to bump to 2.x once builds happen through Xcode.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "ClipboardHistory",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/ClipboardHistory",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ClipboardHistoryTests",
            dependencies: ["ClipboardHistory"],
            path: "Tests/ClipboardHistoryTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
