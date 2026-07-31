import TMUDesign
import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMUWidgets

final class UsageTimelineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    /// The failure this exists to prevent is invisible in production and permanent.
    ///
    /// A single entry with policy .never renders once, while the data is fresh, so it carries
    /// no `?`. If the app then quits, nothing ever asks the widget to render again — and that
    /// frozen number sits on the desktop presenting itself as current for as long as the
    /// widget is placed. One read has to produce its own ageing.
    func testOneReadProducesAStaleEntrySoAFrozenWidgetStopsClaimingToBeCurrent() {
        let entries = UsageTimeline.entries(from: model(at: now), family: .medium, now: now)

        XCTAssertEqual(entries.count, 2, "a fresh entry and the stale one it becomes")
        XCTAssertFalse(entries[0].model.isStale)
        XCTAssertTrue(entries[1].model.isStale)
    }

    /// The transition must land exactly on the threshold every other surface uses. Scheduling
    /// it early marks good data stale; scheduling it late is the bug above with a delay.
    func testTheStaleEntryIsDatedToTheFreshnessThreshold() {
        let entries = UsageTimeline.entries(from: model(at: now), family: .medium, now: now)
        XCTAssertEqual(
            entries[1].date.timeIntervalSince1970,
            now.addingTimeInterval(Thresholds.staleAfter).timeIntervalSince1970,
            accuracy: 0.001)
    }

    /// Data already past the threshold when it is read has no future transition to schedule —
    /// and must not get one dated in the past, which WidgetKit would show immediately and
    /// treat as the timeline being over.
    func testDataThatIsAlreadyStaleProducesASingleEntry() {
        let old = model(at: now.addingTimeInterval(-Thresholds.staleAfter - 60))
        let entries = UsageTimeline.entries(from: old, family: .medium, now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].model.isStale)
    }

    /// Entries must be in ascending date order or WidgetKit discards the out-of-order ones.
    func testEntriesAreInAscendingDateOrder() {
        let entries = UsageTimeline.entries(from: model(at: now), family: .large, now: now)
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
    }

    private func model(at generatedAt: Date) -> TelemetryModel {
        TelemetryModel.build(
            snapshots: [
                UsageSnapshot(
                    provider: "claude", account: "work", observedAt: generatedAt, status: .ok,
                    metrics: [
                        Metric(
                            key: "five-hour", kind: .percentOfLimit, value: 62, limit: 100,
                            window: .rolling(5 * 3600), resetsAt: nil, label: "5-hour")
                    ])
            ],
            now: generatedAt, timeZone: .gmt)
    }
}
