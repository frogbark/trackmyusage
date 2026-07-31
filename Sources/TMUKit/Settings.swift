import Foundation

/// What the user has chosen, shared between the app and the CLI.
///
/// A plain JSON file rather than `UserDefaults`. `tmu` is a one-shot process that reads once
/// and exits, so `cfprefsd` coherence, KVO and `@AppStorage` buy nothing across the two
/// readers. And a file is inspectable and diffable, which matters for a tool whose whole
/// argument is legibility.
///
/// It used to carry a layout per display, chosen by the user and resolved by the wallpaper
/// daemon. WidgetKit owns placement and size now — a widget is put where it is wanted, at the
/// size it is wanted, by dragging it — so that setting is gone rather than reimplemented.
public struct Settings: Codable, Equatable, Sendable {

    public var notificationsEnabled: Bool
    /// Providers the user does not want to see. Their credentials stay put; they are simply
    /// not drawn.
    public var hiddenProviders: Set<String>
    /// How often the app refetches network providers.
    public var providerPollInterval: TimeInterval

    public init(
        notificationsEnabled: Bool = true,
        hiddenProviders: Set<String> = [],
        providerPollInterval: TimeInterval = 300
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.hiddenProviders = hiddenProviders
        self.providerPollInterval = providerPollInterval
    }
}

public enum SettingsStore {

    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/TrackMyUsage")
            .appendingPathComponent("settings.json")
    }

    /// Never throws. A settings file we cannot read is one the user has not written yet, as
    /// far as anything downstream is concerned — the same stance `SnapshotCache.load` takes.
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
