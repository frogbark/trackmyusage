// swift-tools-version: 5.9
import PackageDescription

// native/launcher/launcher.c is deliberately not an SPM target: it is compiled once per
// instance with that instance's data directory baked in, so it has no single build product.
// create-instance.sh drives clang directly.

let package = Package(
    name: "Claudruple",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudrupleKit", targets: ["ClaudrupleKit"]),
        .executable(name: "ClaudrupleLink", targets: ["ClaudrupleLink"]),
    ],
    targets: [
        .target(name: "ClaudrupleKit"),
        .executableTarget(name: "ClaudrupleLink"),
        .testTarget(name: "ClaudrupleKitTests", dependencies: ["ClaudrupleKit"]),
    ]
)
