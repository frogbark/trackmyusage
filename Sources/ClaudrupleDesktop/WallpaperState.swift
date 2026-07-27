import Foundation

/// What has to survive a restart for the wallpaper not to eat itself.
///
/// Without the remembered original, a relaunch sees our own render as the current wallpaper,
/// has nothing else to fall back to, and either composites onto itself or loses the user's
/// photograph permanently. Neither failure raises an error, so the state file is the whole
/// safety net.
public struct WallpaperState: Codable, Sendable, Equatable {

    public struct PerDisplay: Codable, Sendable, Equatable {
        /// The wallpaper as it was before Claudruple first touched it.
        public var pristine: URL?
        /// The filename written last, so the next write can pick the other one.
        public var lastOutput: String?

        public init(pristine: URL? = nil, lastOutput: String? = nil) {
            self.pristine = pristine
            self.lastOutput = lastOutput
        }
    }

    public var displays: [String: PerDisplay]

    public init(displays: [String: PerDisplay] = [:]) {
        self.displays = displays
    }

    public subscript(display: String) -> PerDisplay {
        get { displays[display] ?? PerDisplay() }
        set { displays[display] = newValue }
    }

    // MARK: - Persistence

    /// A missing or unreadable state file is an empty state, not an error.
    ///
    /// The alternative is refusing to run because of a corrupt cache entry, which trades a
    /// recoverable situation for an unrecoverable one.
    public static func load(from url: URL) -> WallpaperState {
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(WallpaperState.self, from: data)
        else { return WallpaperState() }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
