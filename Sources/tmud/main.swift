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
          tmud layout                 which layout each display is set to
          tmud layout <id> <L>        set one display's layout
                                      ("auto" fits it to the display, "default" clears it)
          tmud layout --default <L>   set the layout for displays with no choice
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

/// Every layout name, plus the token that asks for one to be chosen.
///
/// `Settings.layout` discards anything not in this set, so `auto` has to be in it to reach
/// the caller that can resolve it.
let layoutNames = Set(WallpaperLayoutID.allCases.map(\.rawValue) + [LayoutAssignment.automatic])

/// The layout a display gets, resolving `auto` against the display itself.
func chosenLayout(
    for display: Display, settings: Settings, known: Set<String>
) -> WallpaperLayoutID {
    let stored = settings.layout(for: display.id, known: known)
    guard stored != LayoutAssignment.automatic else {
        // designWidth is the canvas normalised to the renderer's 1440-unit design height —
        // the width the layout will actually be laid out against, which is what decides
        // whether the board's tiles fit.
        let designWidth =
            display.canvas.height > 0
            ? display.canvas.width / (display.canvas.height / 1440) : display.canvas.width
        return LayoutFit.layout(points: display.points, designWidth: designWidth)
    }
    return WallpaperLayoutID(rawValue: stored) ?? .ledger
}

struct Rendered {
    let display: Display
    let file: URL
    let origin: URL?
}

/// Renders every display and returns where each image landed.
func renderAll(layout override: WallpaperLayoutID?, into directory: URL) throws -> [Rendered] {
    // A display can have its own layout: a laptop next to a large monitor wants the card on
    // one and the rail on the other, and one global setting cannot serve both. The flag,
    // when given, beats the file — an explicit invocation should do what it says.
    let settings = SettingsStore.load()
    let known = layoutNames
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

        let layout = override ?? chosenLayout(for: display, settings: settings, known: known)

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

/// `tmud layout [<display-id>|--default] [<layout>|auto]`
///
/// Settings has keyed layouts by display id since it was written, and `renderAll` has
/// honoured them for just as long. Nothing could set one: no command wrote the field and no
/// command printed an id, so using the feature meant hand-editing JSON with a key the tool
/// would not tell you. It was shipped and unreachable, which is indistinguishable from
/// missing.
func runLayout(_ args: [String]) throws {
    let known = layoutNames
    var settings = SettingsStore.load()

    // No arguments: report, and print the ids, since that is what the next command needs.
    guard let first = args.first else {
        let desktop = try DesktopFactory.current()
        print("\ndefault: \(settings.defaultLayout)\n")
        for display in try desktop.displays() {
            let assigned = settings.layoutByDisplay[display.id]
            let resolved = chosenLayout(for: display, settings: settings, known: known)
            let source =
                assigned == LayoutAssignment.automatic
                ? "auto" : (assigned == nil ? "default" : "set")
            print("  \(display.name)")
            print("    id      \(display.id)")
            print("    size    \(Int(display.points.width))x\(Int(display.points.height)) pt")
            print("    layout  \(resolved.rawValue)  (\(source))")
        }
        let names = WallpaperLayoutID.allCases.map(\.rawValue).sorted().joined(separator: "|")
        print("\nset one with:    tmud layout <id> \(names)")
        print("or let it pick:  tmud layout <id> auto")
        print("clear one with:  tmud layout <id> default\n")
        return
    }

    guard args.count == 2 else {
        FileHandle.standardError.write(
            Data("usage: tmud layout [<display-id>|--default] [<layout>|auto]\n".utf8))
        exit(2)
    }

    // The rules live in TMUKit, where they are tested. This is the I/O around them.
    switch LayoutAssignment.plan(target: first, choice: args[1], known: known) {
    case .unknownLayout(let name):
        let names = known.sorted().joined(separator: ", ")
        FileHandle.standardError.write(
            Data("unknown layout '\(name)'. Known: \(names), or 'default' to clear.\n".utf8))
        exit(2)

    case .defaultCannotBe(let token):
        let why =
            token == LayoutAssignment.automatic
            ? "it is a rule for one display, not a fallback for the others"
            : "it is what that falls back to"
        FileHandle.standardError.write(
            Data("the default cannot be '\(token)' — \(why)\n".utf8))
        exit(2)

    case .setDefault(let layout):
        settings.defaultLayout = layout
        try SettingsStore.save(settings)
        print("default layout is now \(layout)")

    case .assign(let id, let layout):
        let display = try displayNamed(id)
        settings.layoutByDisplay[id] = layout
        try SettingsStore.save(settings)
        print("\(display.name) is now \(layout)")

    case .clear(let id):
        let display = try displayNamed(id)
        settings.layoutByDisplay.removeValue(forKey: id)
        try SettingsStore.save(settings)
        print("\(display.name) follows the default (\(settings.defaultLayout))")
    }
}

/// The display with this id, or exit.
///
/// Refusing an id no display has: a typo would otherwise be accepted, stored, and do nothing
/// visible, leaving the settings file carrying a key nothing ever reads.
func displayNamed(_ id: String) throws -> Display {
    guard let display = try DesktopFactory.current().displays().first(where: { $0.id == id })
    else {
        FileHandle.standardError.write(
            Data("no display with id '\(id)'. Run `tmud layout` to list them.\n".utf8))
        exit(2)
    }
    return display
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
        // The label, not the key. `key` is a stable identifier for storage; this is a
        // command a person reads, and "five_hour at 2%" is the app's internal vocabulary.
        print(
            "  \(snapshot.provider)\(account)   \(binding.label) at "
                + String(format: "%.0f%%", value))
    }
}

// MARK: - Dispatch

var arguments = Array(CommandLine.arguments.dropFirst())
var layout: WallpaperLayoutID?

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
        let settings = SettingsStore.load()
        let known = layoutNames
        print("\ndisplays:")
        for display in try desktop.displays() {
            let current = desktop.currentWallpaper(for: display)
            let origin = WallpaperOrigin.pristine(
                current: current,
                remembered: WallpaperState.load(
                    from: outputDirectory().appendingPathComponent("state.json")
                )[display.id].pristine,
                outputDirectory: outputDirectory())

            // The layout each display will actually get, and whether that was chosen or
            // inherited. Settings has keyed layouts by display id since it was written and
            // nothing ever printed an id, so the one thing you needed in order to set one
            // was the one thing the tool would not tell you.
            let assigned = settings.layoutByDisplay[display.id]
            let resolved = chosenLayout(for: display, settings: settings, known: known)
            // Says what will be drawn, and where that came from. Printing "auto" alone would
            // name the rule and withhold its answer, which is the one thing being asked.
            let source =
                assigned == LayoutAssignment.automatic
                ? "auto" : (assigned == nil ? "default" : "set")

            print(
                "  \(display.name)  \(Int(display.canvas.width))x"
                    + "\(Int(display.canvas.height))  over "
                    + (origin?.lastPathComponent ?? "a generated background"))
            print("    id      \(display.id)")
            print("    layout  \(resolved.rawValue)  (\(source))")
        }
        print()

    case "layout":
        try runLayout(Array(CommandLine.arguments.dropFirst(2)))

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

    case "--migrate":
        // An explicit re-run, for when a deferred step's precondition has since been met.
        // The usual one is the launch agents: they are skipped until the new binaries are
        // actually installed, and nothing else would prompt a retry until the next fire.
        let receipt = Migration.runOnceIfNeeded(
            legacyKeychainService: KeychainCredentials.legacyService,
            newKeychainService: KeychainCredentials.defaultService,
            force: true)
        guard let receipt, !receipt.outcomes.isEmpty else {
            print("nothing left to migrate")
            break
        }
        for (step, outcome) in receipt.outcomes.sorted(by: { $0.key < $1.key }) {
            print("  \(step)  \(outcome.summary)")
        }

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
