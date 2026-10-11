// swift-tools-version: 6.0
// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import PackageDescription

let package = Package(
    name: "ALStore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ALStore", targets: ["ALStore"]),
    ],
    dependencies: [
        .package(path: "../AdventureLogKit"),
    ],
    targets: [
        .target(
            name: "ALStore",
            dependencies: ["AdventureLogKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ALStoreTests",
            dependencies: ["ALStore", .product(name: "AdventureLogKit", package: "AdventureLogKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
