// swift-tools-version: 5.9
import PackageDescription

// native/launcher/launcher.c is deliberately not an SPM target: it is compiled once per
// instance with that instance's data directory baked in, so it has no single build product.
// create-instance.sh drives clang directly.

let package = Package(
    name: "TrackMyUsage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TMUKit", targets: ["TMUKit"]),
        .library(name: "TMUProviders", targets: ["TMUProviders"]),
        .library(name: "TMURender", targets: ["TMURender"]),
        .library(name: "TMUDesktop", targets: ["TMUDesktop"]),
        .executable(name: "TMULink", targets: ["TMULink"]),
        .executable(name: "tmud", targets: ["tmud"]),
        .executable(name: "tmu", targets: ["tmu"]),
        .executable(name: "TMUApp", targets: ["TMUApp"]),
    ],
    dependencies: [
        // The manifest is meant to be committed to dotfiles repos and shared, so it needs
        // comments — which rules out JSON. Yams is pure Swift and the de facto standard;
        // a hand-rolled YAML subset is where parser bugs live.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        // The palette, the ok/warn/over classification, and the numbers behind them.
        // Depends on nothing, for the same reason TMUProviders does: SwiftUI adapts at the
        // consumer (a Color extension in the app), so this stays buildable anywhere and the
        // SVG renderer keeps emitting plain hex as presentation attributes.
        .target(name: "TMUDesign"),
        .target(name: "TMUKit", dependencies: ["Yams", "TMUDesign"]),
        // Deliberately depends on nothing. TMUKit is macOS-bound — InstanceLocator
        // reads /Applications, SyncApplier imports Darwin — and the usage layer has to
        // build on Linux and Windows, where the wallpaper runs but Claude Desktop does not
        // exist. Claude-specific reading stays behind an adapter that depends on both.
        .target(name: "TMUProviders"),
        // The bridge, and the only place the two worlds meet: Claude's local history is
        // read through TMUKit, then mapped onto the provider-neutral shape.
        .target(
            name: "TMUClaude",
            dependencies: ["TMUKit", "TMUProviders"]),
        // Text in, text out. Producing SVG rather than pixels keeps the whole visual
        // design a pure function that diffs in a golden-file test, and leaves rasterising
        // as the only part that needs a platform.
        .target(name: "TMURender", dependencies: ["TMUProviders", "TMUDesign"]),
        // Reading and writing the desktop background is the one genuinely per-OS piece:
        // NSWorkspace here, a per-desktop-environment shell-out on Linux, and
        // SystemParametersInfoW on Windows.
        .target(name: "TMUDesktop", dependencies: ["TMURender"]),
        .executableTarget(name: "TMULink"),
        .executableTarget(
            name: "tmud",
            dependencies: [
                "TMUDesktop", "TMURender", "TMUProviders",
                "TMUClaude", "TMUKit",
            ]),
        .executableTarget(name: "tmu", dependencies: ["TMUKit", "TMUProviders"]),
        // TMUProviders is here for the keychain service names the migration needs. The
        // provider snapshots themselves are not wired into the app yet.
        .executableTarget(name: "TMUApp", dependencies: ["TMUKit", "TMUProviders", "TMUDesign"]),
        .testTarget(name: "TMUDesignTests", dependencies: ["TMUDesign"]),
        .testTarget(name: "TMUKitTests", dependencies: ["TMUKit"]),
        .testTarget(name: "TMUProvidersTests", dependencies: ["TMUProviders"]),
        .testTarget(
            name: "TMUDesktopTests",
            dependencies: ["TMUDesktop", "TMURender"]),
        .testTarget(
            name: "TMURenderTests",
            dependencies: ["TMURender", "TMUProviders"]),
        .testTarget(
            name: "TMUClaudeTests",
            dependencies: ["TMUClaude", "TMUKit", "TMUProviders"]),
    ]
)
