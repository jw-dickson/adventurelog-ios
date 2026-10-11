// swift-tools-version: 6.0
// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import PackageDescription

let package = Package(
    name: "AdventureLogKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AdventureLogKit", targets: ["AdventureLogKit"]),
    ],
    targets: [
        .target(
            name: "AdventureLogKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AdventureLogKitTests",
            dependencies: ["AdventureLogKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
