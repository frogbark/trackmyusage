import XCTest
@testable import ClaudrupleKit

/// Burn-rate forecasting.
///
/// The hard part is not the arithmetic, it is that utilisation *resets*: the 5-hour window
/// rolls, the weekly cap rolls, and both appear in the data as a sudden drop. A slope
/// fitted across a reset is meaningless — and worse, it is confidently meaningless, which
/// is how a forecast ends up telling someone they have three days of headroom an hour
/// before they run out.
final class UsageForecastTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Samples spaced `everyMinutes` apart, oldest first.
    private func history(_ values: [Double], everyMinutes: Double = 5) -> UsageHistory {
        UsageHistory(
            samples: values.enumerated().map { i, v in
                UsageSample(
                    timestamp: t0.addingTimeInterval(Double(i) * everyMinutes * 60),
                    org: "org", metrics: [.fiveHour: v])
            })
    }

    private func now(afterSamples n: Int, everyMinutes: Double = 5) -> Date {
        t0.addingTimeInterval(Double(n - 1) * everyMinutes * 60)
    }

    // MARK: - Basic rate

    func testRisingUsageProducesAPositiveRate() throws {
        // 0 -> 20 over one hour (13 samples, 5 min apart) = 20 points/hour.
        let h = history(Array(stride(from: 0.0, through: 20.0, by: 20.0 / 12)))
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: now(afterSamples: 13)))

        XCTAssertEqual(f.pointsPerHour, 20, accuracy: 1.0)
        XCTAssertEqual(f.current, 20, accuracy: 0.01)
    }

    func testExhaustionIsProjectedFromTheCurrentRate() throws {
        // At 20% and climbing 20 points/hour, the remaining 80 points take four hours.
        let h = history(Array(stride(from: 0.0, through: 20.0, by: 20.0 / 12)))
        let end = now(afterSamples: 13)
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: end))

        let hours = try XCTUnwrap(f.exhaustionDate).timeIntervalSince(end) / 3600
        XCTAssertEqual(hours, 4, accuracy: 0.3)
    }

    func testFlatUsageNeverExhausts() throws {
        let h = history(Array(repeating: 42, count: 13))
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: now(afterSamples: 13)))

        XCTAssertEqual(f.pointsPerHour, 0, accuracy: 0.001)
        XCTAssertNil(f.exhaustionDate, "a flat rate must not project an exhaustion time")
    }

    // MARK: - Resets

    func testAResetIsExcludedFromTheRate() throws {
        // Climbs to 90, the window rolls, then climbs again from 5. Measuring across the
        // drop would yield a *negative* rate and hide an imminent exhaustion entirely.
        let h = history([50, 70, 90, 5, 10, 15, 20, 25])
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: now(afterSamples: 8)))

        XCTAssertGreaterThan(f.pointsPerHour, 0, "rate must come from the post-reset run")
        XCTAssertEqual(f.current, 25)
    }

    func testRateIgnoresSamplesBeforeTheMostRecentReset() throws {
        // Post-reset run is 5 -> 25 across 20 minutes = 60 points/hour.
        let h = history([50, 70, 90, 5, 10, 15, 20, 25])
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: now(afterSamples: 8)))

        XCTAssertEqual(f.pointsPerHour, 60, accuracy: 2.0)
    }

    // MARK: - Already spent

    func testAlreadyAtTheCapReportsExhausted() throws {
        let h = history([90, 95, 100])
        let f = try XCTUnwrap(h.forecast(for: .fiveHour, now: now(afterSamples: 3)))

        XCTAssertTrue(f.isExhausted)
        XCTAssertEqual(f.current, 100)
    }

    // MARK: - Refusing to guess

    func testASingleSampleYieldsNoForecast() throws {
        let f = try XCTUnwrap(history([30]).forecast(for: .fiveHour, now: now(afterSamples: 1)))
        XCTAssertNil(f.pointsPerHourOrNil, "one point is a value, not a trend")
        XCTAssertNil(f.exhaustionDate)
    }

    func testStaleDataYieldsNoForecast() throws {
        // The app only samples while it runs, so history routinely has multi-day holes.
        // Extrapolating from readings taken days ago would be fiction.
        let h = history([10, 20, 30])
        let muchLater = now(afterSamples: 3).addingTimeInterval(6 * 3600)

        XCTAssertNil(
            h.forecast(for: .fiveHour, now: muchLater),
            "a forecast from stale samples is worse than none")
    }

    // MARK: - Windows scale to the metric

    func testReadingsSpanningMostOfAShortWindowYieldNoRate() throws {
        // Two readings four hours apart, on a limit that resets every five. Almost a whole
        // window sits between them, so anything in between is unobserved — the honest
        // answer is no trend, not a slope drawn through a hole.
        let samples = [
            UsageSample(timestamp: t0, org: "o", metrics: [.fiveHour: 10]),
            UsageSample(
                timestamp: t0.addingTimeInterval(4 * 3600), org: "o", metrics: [.fiveHour: 12]),
        ]
        let f = try XCTUnwrap(
            UsageHistory(samples: samples)
                .forecast(for: .fiveHour, now: t0.addingTimeInterval(4 * 3600)))

        XCTAssertNil(f.pointsPerHourOrNil)
        XCTAssertNil(f.exhaustionDate)
        XCTAssertEqual(f.current, 12, "the latest reading is still reported")
    }

    func testTheSameSpacingIsPerfectlyMeasurableForAWeeklyLimit() throws {
        // Identical spacing, different metric. Four hours is a rounding error against a
        // seven-day window, so 10 -> 12 is a real 0.5/hour trend. A single fixed window
        // would have to be wrong for one of these two cases.
        let samples = [
            UsageSample(timestamp: t0, org: "o", metrics: [.sevenDay: 10]),
            UsageSample(
                timestamp: t0.addingTimeInterval(4 * 3600), org: "o", metrics: [.sevenDay: 12]),
        ]
        let f = try XCTUnwrap(
            UsageHistory(samples: samples)
                .forecast(for: .sevenDay, now: t0.addingTimeInterval(4 * 3600)))

        XCTAssertEqual(f.pointsPerHour, 0.5, accuracy: 0.01)
    }

    func testMissingMetricYieldsNoForecast() throws {
        XCTAssertNil(history([10, 20, 30]).forecast(for: .sevenDayOpus, now: now(afterSamples: 3)))
    }
}
