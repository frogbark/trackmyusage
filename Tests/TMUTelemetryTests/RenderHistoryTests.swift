import TMUProviders
import XCTest

@testable import TMUTelemetry

final class RenderHistoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func model(_ readings: [(String, Double?)]) -> TelemetryModel {
        TelemetryModel.build(
            snapshots: readings.map { name, value in
                UsageSnapshot(
                    provider: name, account: nil, observedAt: now,
                    status: value == nil ? .unavailable("down") : .ok,
                    metrics: value.map {
                        [
                            Metric(
                                key: "usage", kind: .percentOfLimit, value: $0, limit: nil,
                                window: .rolling(3600), resetsAt: nil)
                        ]
                    } ?? [])
            }, now: now)
    }

    func testItKeepsExactlyTheTwelveBarsTheSparklineDraws() {
        var history = RenderHistory()
        for value in 1...20 {
            history.record(model([("github", Double(value))]))
        }
        let series = history.byName["github"] ?? []
        XCTAssertEqual(series.count, RenderHistory.capacity)
        XCTAssertEqual(
            series, Array(9...20).map(Double.init),
            "the oldest readings fall off the front, so the shape is the recent shape")
    }

    /// A gap is honest; a zero is a lie. Recording a failed provider as 0 would draw a bar
    /// claiming the reading was low, when in fact there was no reading.
    func testAProviderWithNoReadingIsSkippedRatherThanRecordedAsZero() {
        var history = RenderHistory()
        history.record(model([("sentry", nil)]))
        XCTAssertNil(history.byName["sentry"])
    }

    func testAnUncappedMeterIsNotRecordedEither() {
        var history = RenderHistory()
        let snapshot = UsageSnapshot(
            provider: "stripe", account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "available", kind: .currency, value: 98_000, limit: nil,
                    window: .none, resetsAt: nil)
            ])
        history.record(TelemetryModel.build(snapshots: [snapshot], now: now))
        XCTAssertNil(
            history.byName["stripe"],
            "revenue has no ceiling, so there is no percentage to plot")
    }

    /// A provider removed months ago should not keep a series alive in the file forever.
    func testRowsThatNoLongerAppearArePruned() {
        var history = RenderHistory()
        history.record(model([("github", 10), ("gone", 20)]))
        history.prune(keeping: ["github"])
        XCTAssertEqual(Array(history.byName.keys), ["github"])
    }

    func testACorruptCacheIsAnEmptyCacheRatherThanAFailure() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-history-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // The sparklines come back within an hour and nothing else depends on this file.
        XCTAssertEqual(RenderHistory.load(from: url), RenderHistory())
    }

    func testItRoundTripsThroughDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var history = RenderHistory()
        history.record(model([("github", 41)]))
        try history.save(to: url)

        XCTAssertEqual(RenderHistory.load(from: url), history)
    }
}
