import Foundation
import TMUClaude
import TMUDesktop
import TMUKit
import TMUProviders
import TMURender
import TMUTelemetry

// Hand-rolled dispatch, matching `tmu`. The whole surface is three verbs and one
// flag; a dependency to parse that would be larger than the thing it parses.

let version = "0.1.0"

func usage() {
    print(
        """
        tmud \(version) — renders the usage wallpaper

        USAGE
          tmud status                 what it would draw, and onto what
          tmud render [--layout L]    write the image, leave the desktop alone
          tmud apply  [--layout L]    write the image and set it as the wallpaper
          tmud --migrate              finish a migration whose steps were deferred

        OPTIONS
          --layout ledger|board|card
                ledger  a left rail naming every provider (default)
                board   tiles across the bottom of a wide desktop
                card    a corner card: a few named, the rest as bare bars

          --density compact|full     deprecated; compact -> card, full -> ledger
        """)
}

func outputDirectory() -> URL {
    let caches =
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return caches.appendingPathComponent("TrackMyUsage/wallpaper", isDirectory: true)
}

/// Everything we know right now, from every adapter that has one.
///
/// Claude comes from local files and needs no credential. Everything else is a network
/// call, and because they all arrive as `UsageSnapshot` nothing below this line cares
/// which is which.
func collect() -> [UsageSnapshot] {
    ClaudeUsage.discover() + external()
}

/// Snapshots from the configured network providers.
///
/// A provider is included when it needs no credential or has one stored. Fetching one that
/// is not set up would spend a render cycle to draw "unauthorized" on someone's desktop.
func external() -> [UsageSnapshot] {
    let credentials = KeychainCredentials()
    let providers = ProviderRegistry.all().filter { provider in
        !provider.credentialSpec.required
            || ((try? credentials.secret(for: provider.id)) ?? nil) != nil
    }
    guard !providers.isEmpty else { return [] }

    let now = Date()
    return runBlocking {
        // Concurrently, deliberately. Serially, seventeen providers each allowed fifteen
        // seconds could stall a render for four minutes; in parallel the slowest one sets
        // the cost. `snapshot` never throws, so a failure occupies its row rather than
        // taking the others down with it.
        await withTaskGroup(of: UsageSnapshot.self) { group in
            for provider in providers {
                group.addTask { await provider.snapshot(credentials: credentials, now: now) }
            }
            var collected: [UsageSnapshot] = []
            for await snapshot in group { collected.append(snapshot) }
            return collected
        }
    }
}

/// The daemon is synchronous and the provider API is async. One bridge, in one place.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

final class Box<T>: @unchecked Sendable { var value: T? }

struct Rendered {
    let display: Display
    let file: URL
    let origin: URL?
}

/// Renders every display and returns where each image landed.
func renderAll(layout: WallpaperLayoutID, into directory: URL) throws -> [Rendered] {
    let desktop = try DesktopFactory.current()
    let displays = try desktop.displays()
    let snapshots = collect()
    let now = Date()

    let stateFile = directory.appendingPathComponent("state.json")
    var state = WallpaperState.load(from: stateFile)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)

    // Build the model once, here, and record this round before drawing. The daemon owns
    // every byte of I/O so the renderer stays a pure function of its inputs — which is what
    // keeps a layout regression failing in `swift test` rather than appearing on a desktop.
    // `tmud` is the only writer of this file; the app reads it.
    let historyFile = directory.appendingPathComponent("history.json")
    var history = RenderHistory.load(from: historyFile)
    let sampled = TelemetryModel.build(snapshots: snapshots, now: now)
    history.record(sampled)
    history.prune(keeping: Set(sampled.services.map(\.name)))
    try? history.save(to: historyFile)

    let model = TelemetryModel.build(
        snapshots: snapshots, history: history.byName, now: now)

    var results: [Rendered] = []
    for display in displays {
        var entry = state[display.id]

        // Never composite onto our own output. Whatever comes back here is either the
        // user's real wallpaper or the one we remembered before first touching it.
        let origin = WallpaperOrigin.pristine(
            current: desktop.currentWallpaper(for: display),
            remembered: entry.pristine,
            outputDirectory: directory)
        if let origin { entry.pristine = origin }

        let svg = WallpaperSVG.render(
            model, layout: layout, canvas: display.canvas)
        let png = try AppKitRasterizer().compose(
            svg: svg, over: origin, canvas: display.canvas)

        // Alternating names: macOS will not reload a wallpaper whose URL is unchanged.
        let name = WallpaperOrigin.outputName(previous: entry.lastOutput)
        let file = directory.appendingPathComponent(name)
        try png.write(to: file, options: .atomic)
        entry.lastOutput = name

        state[display.id] = entry
        results.append(Rendered(display: display, file: file, origin: origin))
    }

    try state.save(to: stateFile)
    return results
}

func describe(_ snapshots: [UsageSnapshot]) {
    guard !snapshots.isEmpty else {
        print("  no providers reporting")
        return
    }
    for snapshot in snapshots.sorted(by: { $0.provider < $1.provider }) {
        let account = snapshot.account.map { " (\($0))" } ?? ""
        guard snapshot.isReporting else {
            let reason: String
            if case .unavailable(let detail) = snapshot.status {
                reason = detail
            } else {
                reason = "unauthorized"
            }
            print("  \(snapshot.provider)\(account)   — \(reason)")
            continue
        }
        guard let binding = snapshot.binding, let value = binding.utilization else {
            print("  \(snapshot.provider)\(account)   no capped metric")
            continue
        }
        print(
            "  \(snapshot.provider)\(account)   \(binding.key) at "
                + String(format: "%.0f%%", value))
    }
}

// MARK: - Dispatch

var arguments = Array(CommandLine.arguments.dropFirst())
var layout = WallpaperLayoutID.ledger

if let index = arguments.firstIndex(of: "--layout") {
    guard index + 1 < arguments.count,
        let parsed = WallpaperLayoutID(rawValue: arguments[index + 1])
    else {
        FileHandle.standardError.write(
            Data("--layout needs ledger, board or card\n".utf8))
        exit(2)
    }
    layout = parsed
    arguments.removeSubrange(index...(index + 1))
}

// The previous spelling. Kept working for a release so an existing LaunchAgent plist, which
// a rebuild does not rewrite, does not start failing on every fire.
if let index = arguments.firstIndex(of: "--density") {
    guard index + 1 < arguments.count,
        let parsed = ["compact": WallpaperLayoutID.card, "full": .ledger][arguments[index + 1]]
    else {
        FileHandle.standardError.write(Data("--density needs compact or full\n".utf8))
        exit(2)
    }
    layout = parsed
    arguments.removeSubrange(index...(index + 1))
}

let command = arguments.first ?? "help"

// Any of the three binaries can be the first thing run after an upgrade, so each migrates.
// This one matters most: launchd runs it every five minutes, so it is usually the first to
// notice. Skipped for help and --version, which must not provoke a keychain prompt.
if !["help", "--help", "-h", "--version"].contains(command) {
    if let receipt = Migration.runOnceIfNeeded(
        legacyKeychainService: KeychainCredentials.legacyService,
        newKeychainService: KeychainCredentials.defaultService)
    {
        for (step, outcome) in receipt.outcomes.sorted(by: { $0.key < $1.key })
        where outcome != .done {
            FileHandle.standardError.write(Data("migration: \(step) \(outcome.summary)\n".utf8))
        }
    }
}

do {
    switch command {
    case "status":
        let snapshots = collect()
        print("\nproviders:")
        describe(snapshots)

        let desktop = try DesktopFactory.current()
        print("\ndisplays:")
        for display in try desktop.displays() {
            let current = desktop.currentWallpaper(for: display)
            let origin = WallpaperOrigin.pristine(
                current: current,
                remembered: WallpaperState.load(
                    from: outputDirectory().appendingPathComponent("state.json")
                )[display.id].pristine,
                outputDirectory: outputDirectory())
            print(
                "  \(display.name)  \(Int(display.canvas.width))x"
                    + "\(Int(display.canvas.height))  over "
                    + (origin?.lastPathComponent ?? "a generated background"))
        }
        print()

    case "render":
        for rendered in try renderAll(layout: layout, into: outputDirectory()) {
            print(
                "\(rendered.display.name): \(rendered.file.path)  (over "
                    + (rendered.origin?.lastPathComponent ?? "a generated background") + ")")
        }

    case "apply":
        let desktop = try DesktopFactory.current()
        for rendered in try renderAll(layout: layout, into: outputDirectory()) {
            try desktop.setWallpaper(rendered.file, for: rendered.display)
            print("\(rendered.display.name): set")
        }

    case "help", "--help", "-h":
        usage()

    case "--version":
        print(version)

    default:
        FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
        usage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
