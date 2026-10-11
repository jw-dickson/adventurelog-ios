// swift-tools-version: 6.0
// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import PackageDescription

let package = Package(
    name: "ALDesign",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ALDesign", targets: ["ALDesign"]),
    ],
    targets: [
        .target(
            name: "ALDesign",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ALDesignTests",
            dependencies: ["ALDesign"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
