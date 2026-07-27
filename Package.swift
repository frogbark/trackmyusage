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
        .executable(name: "claudruple", targets: ["claudruple"]),
        .executable(name: "ClaudrupleApp", targets: ["ClaudrupleApp"]),
    ],
    dependencies: [
        // The manifest is meant to be committed to dotfiles repos and shared, so it needs
        // comments — which rules out JSON. Yams is pure Swift and the de facto standard;
        // a hand-rolled YAML subset is where parser bugs live.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(name: "ClaudrupleKit", dependencies: ["Yams"]),
        .executableTarget(name: "ClaudrupleLink"),
        .executableTarget(name: "claudruple", dependencies: ["ClaudrupleKit"]),
        .executableTarget(name: "ClaudrupleApp", dependencies: ["ClaudrupleKit"]),
        .testTarget(name: "ClaudrupleKitTests", dependencies: ["ClaudrupleKit"]),
    ]
)
