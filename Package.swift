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
        .library(name: "ClaudrupleUsage", targets: ["ClaudrupleUsage"]),
        .library(name: "ClaudrupleRender", targets: ["ClaudrupleRender"]),
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
        // Deliberately depends on nothing. ClaudrupleKit is macOS-bound — InstanceLocator
        // reads /Applications, SyncApplier imports Darwin — and the usage layer has to
        // build on Linux and Windows, where the wallpaper runs but Claude Desktop does not
        // exist. Claude-specific reading stays behind an adapter that depends on both.
        .target(name: "ClaudrupleUsage"),
        // The bridge, and the only place the two worlds meet: Claude's local history is
        // read through ClaudrupleKit, then mapped onto the provider-neutral shape.
        .target(
            name: "ClaudrupleUsageClaude",
            dependencies: ["ClaudrupleKit", "ClaudrupleUsage"]),
        // Text in, text out. Producing SVG rather than pixels keeps the whole visual
        // design a pure function that diffs in a golden-file test, and leaves rasterising
        // as the only part that needs a platform.
        .target(name: "ClaudrupleRender", dependencies: ["ClaudrupleUsage"]),
        .executableTarget(name: "ClaudrupleLink"),
        .executableTarget(name: "claudruple", dependencies: ["ClaudrupleKit"]),
        .executableTarget(name: "ClaudrupleApp", dependencies: ["ClaudrupleKit"]),
        .testTarget(name: "ClaudrupleKitTests", dependencies: ["ClaudrupleKit"]),
        .testTarget(name: "ClaudrupleUsageTests", dependencies: ["ClaudrupleUsage"]),
        .testTarget(
            name: "ClaudrupleRenderTests",
            dependencies: ["ClaudrupleRender", "ClaudrupleUsage"]),
        .testTarget(
            name: "ClaudrupleUsageClaudeTests",
            dependencies: ["ClaudrupleUsageClaude", "ClaudrupleKit", "ClaudrupleUsage"]),
    ]
)
