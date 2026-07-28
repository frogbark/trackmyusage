import XCTest

@testable import ClaudrupleKit

/// Parsing `plan-usage-history.json`.
///
/// The field map is lifted verbatim from the app bundle:
///     {five_hour:"fh", seven_day:"sd", seven_day_opus:"so", seven_day_oauth_apps:"oa",
///      seven_day_cowork:"cw", seven_day_omelette:"om", omelette_promotional:"op",
///      seven_day_sonnet:"sn"}
/// Values are `utilization` percentages (0–100) taken from the plan-usage API response.
final class UsageSampleTests: XCTestCase {

    // MARK: - Metric codes

    func testKnownCodesMapToNamedMetrics() {
        XCTAssertEqual(UsageMetric(code: "fh"), .fiveHour)
        XCTAssertEqual(UsageMetric(code: "sd"), .sevenDay)
        XCTAssertEqual(UsageMetric(code: "so"), .sevenDayOpus)
        XCTAssertEqual(UsageMetric(code: "sn"), .sevenDaySonnet)
        XCTAssertEqual(UsageMetric(code: "cw"), .sevenDayCowork)
        XCTAssertEqual(UsageMetric(code: "oa"), .sevenDayOAuthApps)
        XCTAssertEqual(UsageMetric(code: "om"), .sevenDayOmelette)
        XCTAssertEqual(UsageMetric(code: "op"), .omellettePromotional)
    }

    func testExtraUsageIsItsOwnMetric() {
        // `xu` sits outside the limit map because extra_usage is not a limit — it is the
        // pay-as-you-go credit pool {is_enabled, used_credits, monthly_limit, utilization},
        // which is why its values are fractional where the limits are integral.
        XCTAssertEqual(UsageMetric(code: "xu"), .extraUsage)
    }

    func testUnknownCodesSurviveRatherThanBeingDropped() {
        // Anthropic ships new codes without notice — `xu` itself is absent from the limit
        // map. Discarding unrecognised codes would hide a new limit precisely when a usage
        // tool most needs to surface it.
        XCTAssertEqual(UsageMetric(code: "zz"), .unknown("zz"))
        XCTAssertEqual(UsageMetric(code: "zz").code, "zz")
    }

    func testEveryMetricRoundTripsThroughItsCode() {
        for m in UsageMetric.known + [.unknown("zz")] {
            XCTAssertEqual(UsageMetric(code: m.code), m)
        }
    }

    // MARK: - Schema v2

    func testParsesVersion2Samples() throws {
        let history = try UsageHistory.parse(
            #"""
            {"version":2,"samples":[
              {"t":1784969883372,"org":"8339cad5","u":{"fh":19,"sd":100}}
            ]}
            """#)

        XCTAssertEqual(history.samples.count, 1)
        let s = history.samples[0]
        XCTAssertEqual(s.org, "8339cad5")
        XCTAssertEqual(s.timestamp, Date(timeIntervalSince1970: 1784969883.372))
        XCTAssertEqual(s.metrics[.fiveHour], 19)
        XCTAssertEqual(s.metrics[.sevenDay], 100)
    }

    func testFractionalValuesArePreserved() throws {
        // Real data carries 39.550000000000004; rounding at parse time would quietly
        // lose precision the source took care to keep.
        let history = try UsageHistory.parse(#"{"version":2,"samples":[{"t":1,"u":{"xu":39.55}}]}"#)
        XCTAssertEqual(history.samples[0].metrics[.extraUsage] ?? 0, 39.55, accuracy: 0.0001)
    }

    func testNullOrgIsAllowed() throws {
        let history = try UsageHistory.parse(
            #"{"version":2,"samples":[{"t":1,"org":null,"u":{}}]}"#)
        XCTAssertNil(history.samples[0].org)
    }

    // MARK: - Schema v1 (legacy)

    func testParsesVersion1AndMigratesFlatFields() throws {
        // v1 was {t, fh, sd} with nullable fields and no org. The app migrates it, so a
        // history file predating v2 must still be readable.
        let history = try UsageHistory.parse(
            #"""
            {"version":1,"samples":[{"t":1784969883372,"fh":12,"sd":null}]}
            """#)

        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples[0].metrics[.fiveHour], 12)
        XCTAssertNil(history.samples[0].metrics[.sevenDay], "null must not become zero")
        XCTAssertNil(history.samples[0].org)
    }

    // MARK: - Robustness

    func testEmptySampleListIsValid() throws {
        XCTAssertTrue(try UsageHistory.parse(#"{"version":2,"samples":[]}"#).samples.isEmpty)
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try UsageHistory.parse("{ not json"))
    }

    func testSamplesAreReturnedInChronologicalOrder() throws {
        let history = try UsageHistory.parse(
            #"""
            {"version":2,"samples":[{"t":3000,"u":{}},{"t":1000,"u":{}},{"t":2000,"u":{}}]}
            """#)
        XCTAssertEqual(history.samples.map(\.timestamp.timeIntervalSince1970), [1, 2, 3])
    }
}
