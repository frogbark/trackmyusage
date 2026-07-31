import Foundation

/// The last twelve readings per row, for the rail's sparklines.
///
/// Deliberately a render cache with a documented cap, not a history feature. Twelve is not a
/// tunable — it is exactly the number of bars the design draws, so there is no scenario where
/// keeping more helps anything on screen. Anyone who wants real history wants the local API
/// and a database, which is a different piece of work with different guarantees; pretending
/// this is that would be the worse outcome.
///
/// Single writer by construction: `tmud` appends after each collect, the app only reads.
/// Two processes writing would need locking, and the value at stake is twelve numbers that
/// regenerate within an hour.
public struct RenderHistory: Codable, Equatable, Sendable {

    /// The sparkline is twelve bars wide.
    public static let capacity = 12

    private var series: [String: [Double]]

    public init(series: [String: [Double]] = [:]) {
        self.series = series
    }

    public var byName: [String: [Double]] { series }

    /// Record this round's readings, oldest first, dropping anything past the cap.
    ///
    /// Rows with no utilisation — uncapped meters, failed providers — are skipped rather
    /// than recorded as zero. A gap in the series is honest; a zero would draw a bar
    /// claiming the reading was low when in fact there was no reading.
    public mutating func record(_ model: TelemetryModel) {
        for row in model.services {
            guard let utilization = row.utilization else { continue }
            var values = series[row.name] ?? []
            values.append(utilization)
            if values.count > Self.capacity {
                values.removeFirst(values.count - Self.capacity)
            }
            series[row.name] = values
        }
    }

    /// Forget rows that no longer appear, so a provider removed months ago does not keep a
    /// series alive in the file forever.
    public mutating func prune(keeping names: Set<String>) {
        series = series.filter { names.contains($0.key) }
    }

    // MARK: - Persistence

    /// Never throws. A cache that cannot be read is an empty cache; the sparklines come back
    /// within an hour and nothing else depends on it. Same stance `SnapshotCache.load`
    /// takes toward a corrupt file.
    public static func load(from url: URL) -> RenderHistory {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(RenderHistory.self, from: data)
        else { return RenderHistory() }
        return decoded
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
