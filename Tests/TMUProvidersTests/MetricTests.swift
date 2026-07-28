import XCTest

@testable import TMUProviders

final class MetricTests: XCTestCase {

    // MARK: - Utilisation

    func testPercentOfLimitReportsItsValueDirectly() {
        // Claude's plan-usage file already carries utilisation percentages, so there is
        // nothing to divide — re-deriving one would only introduce rounding.
        let m = Metric(
            key: "five_hour", kind: .percentOfLimit, value: 78,
            limit: nil, window: .rolling(5 * 3600), resetsAt: nil)

        XCTAssertEqual(m.utilization, 78, "a percentage metric is its own utilisation")
    }

    func testAbsoluteValueIsDividedByItsLimit() {
        let m = Metric(
            key: "credits", kind: .absolute, value: 250,
            limit: 1000, window: .calendarMonth, resetsAt: nil)

        XCTAssertEqual(m.utilization, 25, "250 of 1000 is 25%")
    }

    func testAbsoluteValueWithoutALimitHasNoUtilisation() {
        // Stripe reports revenue, which has no cap. A metric with nothing to be a
        // percentage *of* must say so rather than inventing a denominator.
        let m = Metric(
            key: "revenue_usd", kind: .currency, value: 4200,
            limit: nil, window: .calendarMonth, resetsAt: nil)

        XCTAssertNil(m.utilization, "no limit means no utilisation")
    }

    func testAZeroLimitHasNoUtilisationRatherThanInfinity() {
        // A provider on a free tier can genuinely report a quota of zero. Dividing gives
        // infinity, which then sorts as the binding limit and pins every gauge to full.
        let m = Metric(
            key: "seats", kind: .count, value: 3,
            limit: 0, window: .none, resetsAt: nil)

        XCTAssertNil(m.utilization, "a zero limit is unusable as a denominator")
    }

    func testUtilisationAboveOneHundredIsPreservedNotClamped() {
        // Overage is real and worth seeing. Clamping to 100 makes "at the cap" and
        // "double the cap" look identical at exactly the moment the difference matters.
        let m = Metric(
            key: "requests", kind: .absolute, value: 1500,
            limit: 1000, window: .calendarMonth, resetsAt: nil)

        XCTAssertEqual(m.utilization, 150, "overage is reported, not hidden")
        XCTAssertTrue(m.isOverLimit)
    }

    func testAMetricWithoutAUtilisationIsNeverOverItsLimit() {
        let m = Metric(
            key: "revenue_usd", kind: .currency, value: 4200,
            limit: nil, window: .calendarMonth, resetsAt: nil)

        XCTAssertFalse(m.isOverLimit, "an uncapped metric cannot exceed a cap")
    }
}
