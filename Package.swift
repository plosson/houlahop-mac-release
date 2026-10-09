// swift-tools-version:5.9
import PackageDescription

// Apps use this package through the scripts/mac-release submodule (a local package in project.yml), so the
// Sparkle version below and SPARKLE_VERSION in lib.sh are pinned together.
let package = Package(
    name: "HoulahopUpdater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HoulahopUpdater", targets: ["HoulahopUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "HoulahopUpdater", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    ]
)
