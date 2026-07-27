import ClaudrupleDesktop
import ClaudrupleRender
import ClaudrupleUsage
import ClaudrupleUsageClaude
import Foundation

// Hand-rolled dispatch, matching `claudruple`. The whole surface is three verbs and one
// flag; a dependency to parse that would be larger than the thing it parses.

let version = "0.1.0"

func usage() {
    print(
        """
        claudrupled \(version) — renders the usage wallpaper

        USAGE
          claudrupled status                 what it would draw, and onto what
          claudrupled render [--density D]   write the image, leave the desktop alone
          claudrupled apply  [--density D]   write the image and set it as the wallpaper

        OPTIONS
          --density compact|full   compact: a corner card naming a few providers
                                   full:    a rail naming every provider (default)
        """)
}

func outputDirectory() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return caches.appendingPathComponent("Claudruple/wallpaper", isDirectory: true)
}

/// Everything we know right now, from every adapter that has one.
///
/// Only Claude today. The other sixteen plug in here, and because they all arrive as
/// `UsageSnapshot` nothing below this line changes when they do.
func collect() -> [UsageSnapshot] {
    ClaudeUsage.discover()
}

struct Rendered {
    let display: Display
    let file: URL
    let origin: URL?
}

/// Renders every display and returns where each image landed.
func renderAll(density: WallpaperDensity, into directory: URL) throws -> [Rendered] {
    let desktop = try DesktopFactory.current()
    let displays = try desktop.displays()
    let snapshots = collect()
    let now = Date()

    let stateFile = directory.appendingPathComponent("state.json")
    var state = WallpaperState.load(from: stateFile)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)

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
            snapshots, density: density, canvas: display.canvas, generatedAt: now)
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
            if case .unavailable(let detail) = snapshot.status { reason = detail } else {
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
var density = WallpaperDensity.full

if let index = arguments.firstIndex(of: "--density") {
    guard index + 1 < arguments.count,
        let parsed = WallpaperDensity(rawValue: arguments[index + 1])
    else {
        FileHandle.standardError.write(Data("--density needs compact or full\n".utf8))
        exit(2)
    }
    density = parsed
    arguments.removeSubrange(index...(index + 1))
}

let command = arguments.first ?? "help"

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
        for rendered in try renderAll(density: density, into: outputDirectory()) {
            print(
                "\(rendered.display.name): \(rendered.file.path)  (over "
                    + (rendered.origin?.lastPathComponent ?? "a generated background") + ")")
        }

    case "apply":
        let desktop = try DesktopFactory.current()
        for rendered in try renderAll(density: density, into: outputDirectory()) {
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
