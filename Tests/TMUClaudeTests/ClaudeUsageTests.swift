import TMUKit
import TMUProviders
import XCTest

@testable import TMUClaude

final class ClaudeUsageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    private func account(
        _ samples: [(Date, [UsageMetric: Double])], name: String = "Work"
    ) -> AccountUsage {
        AccountUsage(
            instanceName: name,
            bundleID: "com.anthropic.claudefordesktop.claudruple.work",
            history: UsageHistory(
                samples: samples.map {
                    UsageSample(timestamp: $0.0, org: "org-uuid", metrics: $0.1)
                }))
    }

    // MARK: - Mapping

    func testFiveHourBecomesAPercentageMetric() {
        let snapshot = ClaudeUsage.snapshot(of: account([(t0, [.fiveHour: 78])]))
        let five = snapshot.metrics.first { $0.key == "five_hour" }

        XCTAssertEqual(five?.kind, .percentOfLimit, "the file already carries percentages")
        XCTAssertEqual(
            five?.utilization, 78,
            "utilisation passes through untouched rather than being re-derived")
    }

    func testTheWindowIsCarriedThroughFromTheMetric() {
        let snapshot = ClaudeUsage.snapshot(of: account([(t0, [.sevenDay: 40])]))

        XCTAssertEqual(
            snapshot.metrics.first?.window, .rolling(7 * 24 * 3600),
            "a weekly cap must not be drawn as if it reset every five hours")
    }

    func testObservedAtIsTheSampleTimeNotTheCurrentTime() {
        // Staleness is decided downstream, and it can only be decided if the snapshot
        // reports when the reading was actually taken.
        let snapshot = ClaudeUsage.snapshot(of: account([(t0, [.fiveHour: 12])]))

        XCTAssertEqual(snapshot.observedAt, t0)
    }

    func testOnlyTheNewestSampleIsReported() {
        let snapshot = ClaudeUsage.snapshot(
            of: account([
                (t0, [.fiveHour: 10]),
                (t0.addingTimeInterval(600), [.fiveHour: 55]),
            ]))

        XCTAssertEqual(snapshot.metrics.first?.value, 55, "a snapshot is the latest reading")
    }

    // MARK: - What may not bind

    func testExtraUsageCannotBindBecauseItIsNotALimit() {
        // Mirrors the rule in Steering: a pay-as-you-go credit pool is not a cap, and
        // letting it bind would advise abandoning a session over a credit balance.
        let snapshot = ClaudeUsage.snapshot(
            of: account([(t0, [.extraUsage: 92, .fiveHour: 30])]))

        XCTAssertNotNil(
            snapshot.metrics.first { $0.key == "extra_usage" },
            "it is still shown — it just cannot be the binding limit")
        XCTAssertEqual(snapshot.binding?.key, "five_hour")
    }

    func testAnUnrecognisedCodeSurvivesButDoesNotBind() {
        // `xu` shipped in real history files while absent from the app's limit map, so
        // another will. Dropping it would hide a new limit; letting it bind would let a
        // field of unknown semantics drive advice.
        let snapshot = ClaudeUsage.snapshot(
            of: account([(t0, [.unknown("zz"): 99, .fiveHour: 30])]))

        XCTAssertNotNil(snapshot.metrics.first { $0.key == "zz" }, "preserved, not dropped")
        XCTAssertEqual(snapshot.binding?.key, "five_hour")
    }

    func testTheBindingLimitIsTheOneNearestItsCap() {
        let snapshot = ClaudeUsage.snapshot(
            of: account([(t0, [.fiveHour: 30, .sevenDay: 88, .sevenDayOpus: 12])]))

        XCTAssertEqual(snapshot.binding?.key, "seven_day")
    }

    // MARK: - Absence

    func testAnAccountWithNoHistoryIsUnavailableRatherThanEmpty() {
        let snapshot = ClaudeUsage.snapshot(of: account([]))

        XCTAssertFalse(
            snapshot.isReporting,
            "no history is a gap, not a reading of zero")
        XCTAssertNil(snapshot.binding)
    }

    func testTheInstanceNameIdentifiesTheAccount() {
        let snapshot = ClaudeUsage.snapshot(of: account([(t0, [.fiveHour: 5])], name: "Personal"))

        XCTAssertEqual(snapshot.provider, "claude")
        XCTAssertEqual(
            snapshot.account, "Personal",
            "several Claude accounts coexist, so the snapshot must say which one")
    }

    /// Every surface that shows what a percentage is a percentage *of* reads this label.
    ///
    /// `Metric.label` falls back to `key` when none is given, so omitting it does not fail —
    /// it just quietly puts the app's internal vocabulary on screen. The menu bar shipped
    /// reading "five_hour" and "seven_day" under the account names, and UsageMetric had
    /// carried the readable versions the whole time.
    func testMetricsCarryTheReadableWindowNameRatherThanTheStorageKey() {
        let snapshot = ClaudeUsage.snapshot(
            of: account([(t0, [.fiveHour: 78, .sevenDay: 40])]))

        let labels: [String] = snapshot.metrics.map { $0.label }
        XCTAssertFalse(
            labels.contains(where: { $0.contains("_") }),
            "a label with an underscore is a storage key that reached the screen: \(labels)")
        XCTAssertTrue(
            labels.contains("5-hour") || labels.contains("Weekly"),
            "expected UsageMetric.displayName, got \(labels)")
    }

}
