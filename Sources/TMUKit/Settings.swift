import Foundation

/// What the user has chosen, shared between the app and the daemon.
///
/// A plain JSON file rather than `UserDefaults`, for four reasons. `tmud` is a one-shot
/// process launched by launchd every five minutes — it reads once and exits, so `cfprefsd`
/// coherence, KVO and `@AppStorage` buy nothing. The repo already has this exact pattern
/// working and tested in `WallpaperState`, and a second copy of a known-good mechanism is
/// cheaper than a second mechanism. A file is inspectable and diffable, which matters for a
/// tool whose whole argument is legibility. And `@AppStorage` cannot express
/// `[displayID: Layout]` without hand-encoding it to a string anyway.
public struct Settings: Codable, Equatable, Sendable {

    /// Which layout each display gets. Keyed by `Display.id`.
    public var layoutByDisplay: [String: String]
    /// What a display with no explicit choice gets.
    public var defaultLayout: String
    public var notificationsEnabled: Bool
    /// Providers the user does not want to see. Their credentials stay put; they are simply
    /// not drawn.
    public var hiddenProviders: Set<String>
    /// How often the app refetches network providers.
    public var providerPollInterval: TimeInterval

    public init(
        layoutByDisplay: [String: String] = [:],
        defaultLayout: String = "ledger",
        notificationsEnabled: Bool = true,
        hiddenProviders: Set<String> = [],
        providerPollInterval: TimeInterval = 300
    ) {
        self.layoutByDisplay = layoutByDisplay
        self.defaultLayout = defaultLayout
        self.notificationsEnabled = notificationsEnabled
        self.hiddenProviders = hiddenProviders
        self.providerPollInterval = providerPollInterval
    }

    /// The layout for one display, falling back to the default.
    ///
    /// `known` is the set of layout names this build understands. A newer app writing
    /// `board` must not brick an older daemon that has never heard of it — the unknown value
    /// decodes fine and simply loses to the default, rather than failing the whole file and
    /// discarding every other setting with it.
    public func layout(for displayID: String, known: Set<String>) -> String {
        if let chosen = layoutByDisplay[displayID], known.contains(chosen) { return chosen }
        return known.contains(defaultLayout) ? defaultLayout : "ledger"
    }
}

/// What `tmud layout <target> <choice>` should do, decided before anything is written.
///
/// A separate type because the rules are worth testing and `tmud` is an executable target,
/// where they would not be. The command becomes a switch over the outcome, which is the
/// same split the rest of the project uses: the executable owns I/O, the library owns the
/// decision.
public enum LayoutAssignment {

    public enum Outcome: Equatable, Sendable {
        case setDefault(String)
        case assign(display: String, layout: String)
        case clear(display: String)
        /// The name is not a layout this build understands.
        ///
        /// Rejected rather than stored: an unknown value decodes fine and then loses to the
        /// default at render time, so the setting would look accepted and change nothing.
        case unknownLayout(String)
        /// The clearing token means "fall back to the default", so the default cannot be it.
        case defaultCannotBeClearing
    }

    /// The token that clears a display's own choice.
    ///
    /// "default", not "auto". It means "follow the default", which is what `default` says
    /// and what `auto` only implies — and `auto` is the obvious name for choosing a layout
    /// from the display's own size, which is the next thing this wants to grow. Spending it
    /// on the fallback would have meant taking it back later.
    public static let clearing = "default"

    public static func plan(target: String, choice: String, known: Set<String>) -> Outcome {
        guard choice == clearing || known.contains(choice) else {
            return .unknownLayout(choice)
        }
        guard target == "--default" else {
            return choice == clearing
                ? .clear(display: target)
                : .assign(
                    display: target, layout: choice)
        }
        return choice == clearing ? .defaultCannotBeClearing : .setDefault(choice)
    }
}

public enum SettingsStore {

    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/TrackMyUsage")
            .appendingPathComponent("settings.json")
    }

    /// Never throws. A settings file we cannot read is one the user has not written yet, as
    /// far as anything downstream is concerned — the same stance `WallpaperState.load` takes.
    /// Refusing to start because a preferences file has a stray comma would be worse than
    /// any preference it contains.
    public static func load(from url: URL = SettingsStore.url()) -> Settings {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    public static func save(_ settings: Settings, to url: URL = SettingsStore.url()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
