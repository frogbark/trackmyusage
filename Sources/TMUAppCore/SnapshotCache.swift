import Foundation
import TMUProviders

/// The last good set of provider readings, so the popover is never blank at launch.
///
/// Opening the menu bar to an empty panel while a network round-trip completes reads as a
/// broken app. Showing the previous readings does not risk misleading anyone, because each
/// snapshot carries its real `observedAt` — so anything older than half an hour is marked
/// `?` the moment it is drawn, by the same rule everything else uses. Instant, honest, and
/// self-correcting once the first fetch lands.
public struct SnapshotCache: Sendable {

    private let url: URL

    public init(url: URL? = nil) {
        self.url =
            url
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrackMyUsage/snapshots.json")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-snapshots.json")
    }

    /// Never throws. A cache that will not decode is an empty cache; the real readings are
    /// seconds away and refusing to launch over a stale file would be absurd.
    public func load() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([UsageSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    public func save(_ snapshots: [UsageSnapshot]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshots).write(to: url, options: .atomic)
    }
}
