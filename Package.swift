// swift-tools-version: 5.9
import PackageDescription

// native/launcher/launcher.c is deliberately not an SPM target: it is compiled once per
// instance with that instance's data directory baked in, so it has no single build product.
// create-instance.sh drives clang directly.

let package = Package(
    name: "TrackMyUsage",
    // macOS 14 is the floor because desktop widget placement is, and a widget in Notification
    // Center only would be a lesser thing than the wallpaper it replaces rather than a
    // better one. WidgetKit itself goes back to 11; the desktop does not.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TMUKit", targets: ["TMUKit"]),
        .library(name: "TMUProviders", targets: ["TMUProviders"]),
        .library(name: "TMUWidgets", targets: ["TMUWidgets"]),
        .executable(name: "TMULink", targets: ["TMULink"]),
        .executable(name: "tmu", targets: ["tmu"]),
        .executable(name: "TMUApp", targets: ["TMUApp"]),
        .executable(name: "TMUWidgetExtension", targets: ["TMUWidgetExtension"]),
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
        // consumer (a Color extension in TMUWidgets), so this stays buildable anywhere —
        // which the Linux job in CI proves on every push.
        .target(name: "TMUDesign"),
        .target(name: "TMUKit", dependencies: ["Yams", "TMUDesign"]),
        // Deliberately depends on nothing. TMUKit is macOS-bound — InstanceLocator reads
        // /Applications, SyncApplier imports Darwin — and the usage layer must stay portable
        // so an adapter can be written and tested anywhere. Claude-specific reading stays
        // behind an adapter that depends on both.
        .target(name: "TMUProviders"),
        // The bridge, and the only place the two worlds meet: Claude's local history is
        // read through TMUKit, then mapped onto the provider-neutral shape.
        .target(
            name: "TMUClaude",
            dependencies: ["TMUKit", "TMUProviders"]),
        // The shape every surface renders: raw snapshots interpreted once, so the widget and
        // the menu bar cannot disagree about what a reading means. Also holds DemoSnapshots,
        // the frozen fixtures the website images and the goldens are both built from.
        .target(name: "TMUTelemetry", dependencies: ["TMUProviders", "TMUDesign"]),
        // The widget's view model and its views. A library rather than code inside the
        // extension because three consumers import it: the extension, `tmu assets` for the
        // website images, and the tests. Views living inside the executable would put the
        // website's real source out of the CLI's reach, and the images would go back to
        // being a mockup of the thing rather than the thing.
        //
        // Deliberately no TMUKit and no TMUProviders. The extension is sandboxed and has no
        // business reaching the keychain, the network or /Applications — a dependency it
        // cannot use is a dependency that cannot be misused later.
        //
        // Deliberately no WidgetKit either: the only thing that wants it is
        // `containerBackground(for: .widget)`, which the extension applies as a wrapper. Were
        // it inside the shared view, the CLI and test renders would exercise a path that
        // behaves differently outside a widget host, and the committed images would stop
        // being evidence of what the widget actually draws.
        .target(name: "TMUWidgets", dependencies: ["TMUTelemetry", "TMUDesign"]),
        .executableTarget(name: "TMUWidgetExtension", dependencies: ["TMUWidgets"]),
        .executableTarget(name: "TMULink"),
        // TMUWidgets is here for `assets widget`, which emits the website's images from the
        // code that draws the real widget rather than from a mockup.
        .executableTarget(
            name: "tmu",
            dependencies: ["TMUKit", "TMUProviders", "TMUDesign", "TMUWidgets"]),
        // The app, minus its @main and its Scenes. Splitting the library out is what makes
        // any of it testable: an executable target cannot be @testable imported cleanly, and
        // everything worth testing here is view-model logic anyway.
        .target(
            name: "TMUAppCore",
            dependencies: [
                "TMUKit", "TMUProviders", "TMUClaude", "TMUTelemetry", "TMUDesign",
                // For SharedContainer (the app publishes what the widget reads) and for the
                // one SwiftUI palette adapter, which lives with the views rather than being
                // written out twice.
                "TMUWidgets",
            ]),
        .executableTarget(name: "TMUApp", dependencies: ["TMUAppCore"]),
        .testTarget(name: "TMUDesignTests", dependencies: ["TMUDesign"]),
        .testTarget(
            name: "TMUWidgetsTests",
            dependencies: ["TMUWidgets", "TMUTelemetry", "TMUProviders", "TMUDesign"]),
        .testTarget(name: "TMUAppCoreTests", dependencies: ["TMUAppCore"]),
        .testTarget(
            name: "TMUTelemetryTests",
            dependencies: ["TMUTelemetry", "TMUProviders", "TMUDesign"]),
        .testTarget(name: "TMUKitTests", dependencies: ["TMUKit"]),
        .testTarget(name: "TMUProvidersTests", dependencies: ["TMUProviders"]),
        .testTarget(
            name: "TMUClaudeTests",
            dependencies: ["TMUClaude", "TMUKit", "TMUProviders"]),
    ]
)
