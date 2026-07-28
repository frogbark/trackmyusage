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

    public static let agents = [
        Agent(oldLabel: "com.claudruple.link", newLabel: "com.trackmyusage.link"),
        Agent(oldLabel: "com.claudruple.wallpaper", newLabel: "com.trackmyusage.wallpaper"),
    ]

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
