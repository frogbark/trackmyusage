import Foundation

/// Where an install put things before the rename, and where it puts them now.
///
/// One table, so the migration and the code that reads these locations cannot disagree
/// about what moved. Anything absent from this table is not migrated — which is the point
/// of the `frozen` section at the bottom.
public enum LegacyPaths {

    // MARK: - Directories that move

    /// Rendered wallpapers and `state.json`.
    public static func caches(home: URL) -> Move {
        Move(
            old: home.appendingPathComponent("Library/Caches/Claudruple"),
            new: home.appendingPathComponent("Library/Caches/TrackMyUsage"))
    }

    /// Broker and wallpaper logs.
    public static func logs(home: URL) -> Move {
        Move(
            old: home.appendingPathComponent("Library/Logs/Claudruple"),
            new: home.appendingPathComponent("Library/Logs/TrackMyUsage"))
    }

    // MARK: - Files that move out of a directory that does not

    /// `~/Library/Application Support/Claudruple` holds **instance profiles** and is frozen
    /// (see `LegacyNames.instanceProfileDirectory`). A handful of files we own were written
    /// alongside them; those move, named one by one.
    ///
    /// An allowlist rather than "everything that is not a profile directory": a rule phrased
    /// as an exclusion silently starts moving anything a future version writes there, and the
    /// thing it would move is somebody's signed-in Claude account.
    public static let ownedFilesInInstanceSupport = [
        "original-wallpaper.txt"
    ]

    public static func instanceSupportDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(LegacyNames.instanceProfileDirectory)
    }

    /// Our own support directory — settings, the migration receipt. New; nothing to move.
    public static func supportDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/TrackMyUsage")
    }

    // MARK: - Launch agents

    /// Agents that get renamed and keep running.
    ///
    /// The wallpaper agent is deliberately not here any more. Renaming an agent that is about
    /// to be deleted would bootstrap a fresh copy of it, on a 300s timer, pointing at a `tmud`
    /// that no longer exists — the feature removal doing the exact damage it exists to
    /// prevent. It is in `wallpaperAgentLabels` instead, which is a removal list.
    public static let agents = [
        Agent(oldLabel: "com.claudruple.link", newLabel: "com.trackmyusage.link")
    ]

    /// Agents that get removed, under every label they have ever had.
    ///
    /// Both, because an install may have been migrated to the new label before the wallpaper
    /// feature was dropped, or may still be on the old one. Booting out a label that is not
    /// loaded is not an error, so trying both is free and missing one leaves a timer firing
    /// every five minutes at a binary that is gone.
    public static let wallpaperAgentLabels = [
        "com.claudruple.wallpaper",
        "com.trackmyusage.wallpaper",
    ]

    /// Where the wallpaper agent recorded the background it replaced.
    ///
    /// Checked in both the pre- and post-rename support directories: `.ownedFiles` moves it,
    /// and teardown must work whether or not that step has already run.
    public static func recordedOriginalWallpaper(home: URL) -> [URL] {
        [
            supportDirectory(home: home),
            instanceSupportDirectory(home: home),
        ].map { $0.appendingPathComponent("original-wallpaper.txt") }
    }

    /// The rendered wallpapers themselves, under both cache roots.
    public static func renderedWallpaperDirectories(home: URL) -> [URL] {
        let caches = self.caches(home: home)
        return [caches.new, caches.old].map { $0.appendingPathComponent("wallpaper") }
    }

    public static func launchAgentsDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents")
    }

    // MARK: - Types

    public struct Move: Equatable, Sendable {
        public let old: URL
        public let new: URL
    }

    public struct Agent: Equatable, Sendable {
        public let oldLabel: String
        public let newLabel: String

        public func oldPlist(home: URL) -> URL {
            LegacyPaths.launchAgentsDirectory(home: home)
                .appendingPathComponent("\(oldLabel).plist")
        }

        public func newPlist(home: URL) -> URL {
            LegacyPaths.launchAgentsDirectory(home: home)
                .appendingPathComponent("\(newLabel).plist")
        }
    }
}
