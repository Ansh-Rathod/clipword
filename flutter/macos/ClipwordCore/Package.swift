// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipwordCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ClipwordCore", targets: ["ClipwordCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.2.0"),
        .package(url: "https://github.com/krisk/fuse-swift", from: "1.4.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "ClipwordCore",
            dependencies: [
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Fuse", package: "fuse-swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xfrontend", "-disable-access-control"]),
            ]
        ),
    ]
)
