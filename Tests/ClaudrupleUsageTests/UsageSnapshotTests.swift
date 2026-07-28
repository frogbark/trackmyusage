import XCTest

@testable import ClaudrupleUsage

final class UsageSnapshotTests: XCTestCase {

    private let observed = Date(timeIntervalSince1970: 1_784_000_000)

    private func metric(
        _ key: String, _ value: Double, limit: Double?, kind: MetricKind = .absolute
    ) -> Metric {
        Metric(key: key, kind: kind, value: value, limit: limit, window: .none, resetsAt: nil)
    }

    // MARK: - The binding limit

    func testBindingIsTheMetricClosestToItsCap() {
        let snapshot = UsageSnapshot(
            provider: "vercel", account: "team", observedAt: observed, status: .ok,
            metrics: [
                metric("bandwidth", 200, limit: 1000),  // 20%
                metric("builds", 90, limit: 100),  // 90%
                metric("functions", 500, limit: 2000),  // 25%
            ])

        XCTAssertEqual(
            snapshot.binding?.key, "builds",
            "the limit that will actually stop work is the one nearest its cap")
    }

    func testUncappedMetricsNeverBind() {
        // Revenue is the case that motivated this: a large number with no limit would
        // otherwise sort to the top and be reported as the thing about to run out.
        let snapshot = UsageSnapshot(
            provider: "stripe", account: nil, observedAt: observed, status: .ok,
            metrics: [
                metric("revenue_usd", 98_000, limit: nil, kind: .currency),
                metric("api_requests", 10, limit: 1000),
            ])

        XCTAssertEqual(
            snapshot.binding?.key, "api_requests",
            "only a metric with a cap can be the binding one")
    }

    func testThereIsNoBindingWhenNothingHasALimit() {
        let snapshot = UsageSnapshot(
            provider: "stripe", account: nil, observedAt: observed, status: .ok,
            metrics: [metric("revenue_usd", 98_000, limit: nil, kind: .currency)])

        XCTAssertNil(snapshot.binding, "nothing here can run out")
    }

    // MARK: - Availability

    func testAnUnavailableProviderIsDistinctFromOneReportingZero() {
        // Tier 4 providers may have no usable usage API at all. Rendering that as 0%
        // would read as "plenty of headroom" — the opposite of "we do not know".
        let unavailable = UsageSnapshot(
            provider: "openart", account: nil, observedAt: observed,
            status: .unavailable("no public usage API"), metrics: [])
        let zero = UsageSnapshot(
            provider: "modal", account: nil, observedAt: observed, status: .ok,
            metrics: [metric("compute_hours", 0, limit: 100)])

        XCTAssertFalse(unavailable.isReporting)
        XCTAssertTrue(zero.isReporting)
        XCTAssertNil(unavailable.binding, "an unavailable provider has nothing to bind")
        XCTAssertEqual(zero.binding?.utilization, 0, "zero usage is a real reading")
    }

    func testUnauthorizedIsNotReporting() {
        let snapshot = UsageSnapshot(
            provider: "openai", account: nil, observedAt: observed,
            status: .unauthorized, metrics: [])

        XCTAssertFalse(
            snapshot.isReporting,
            "a missing or rejected credential is a gap, not a measurement")
    }
}
