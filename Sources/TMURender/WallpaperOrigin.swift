import Foundation

/// Decides which image the overlay is drawn onto, and under what name it is written.
///
/// Both halves exist because of failure modes that produce no error at all — one makes the
/// desktop slowly worse, the other makes it silently stale.
public enum WallpaperOrigin {

    /// The pristine background to composite onto, or nil when none is known.
    ///
    /// Anything inside our own output directory is rejected on both paths, including the
    /// remembered one. Compositing onto a previous render stacks the overlay on itself
    /// every cycle: no error is raised, nothing fails, the desktop simply accumulates
    /// scrims until it is unreadable. A guard is the only thing that catches it.
    /// A path that no longer resolves is skipped rather than returned.
    ///
    /// Found on a real machine: macOS reported a wallpaper inside a third-party wallpaper
    /// app's container that the app had since deleted. The path comes back perfectly
    /// happily and the file is not there. Treating that as fatal means the daemon stops
    /// working because another application tidied up its own cache.
    public static func pristine(
        current: URL?, remembered: URL?, outputDirectory: URL,
        isReadable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }
    ) -> URL? {
        for candidate in [current, remembered].compactMap({ $0 }) {
            guard !isInside(candidate, outputDirectory) else { continue }
            guard isReadable(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// The filename to write next, given the one written last.
    ///
    /// macOS will not reload a wallpaper whose URL has not changed, so writing to a single
    /// path updates the file and leaves the screen showing the old image. Alternating
    /// between two names guarantees the URL differs every time; two is sufficient, because
    /// the only requirement is that consecutive writes disagree.
    public static func outputName(previous: String?) -> String {
        previous == names.first ? names[1] : names[0]
    }

    private static let names = ["desktop-a.png", "desktop-b.png"]

    /// Containment by path component, never by string prefix.
    ///
    /// `…/TrackMyUsage/wallpaper-backups/lake.jpg` begins with `…/TrackMyUsage/wallpaper` as
    /// characters while being a different directory entirely. A prefix test would classify
    /// a real photograph as our own output and throw it away.
    private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        let child = resolve(url)
        let parent = resolve(directory)
        guard child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    private static func resolve(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
