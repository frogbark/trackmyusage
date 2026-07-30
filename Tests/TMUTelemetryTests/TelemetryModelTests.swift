import TMUDesign
import TMUProviders
import XCTest

@testable import TMUTelemetry

final class TelemetryModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Helpers

    private func snapshot(
        _ provider: String,
        account: String? = nil,
        value: Double = 50,
        limit: Double? = 100,
        kind: MetricKind = .absolute,
        observedAt: Date? = nil,
        resetsAt: Date? = nil,
        key: String = "quota",
        label: String? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: account, observedAt: observedAt ?? now, status: .ok,
            metrics: [
                Metric(
                    key: key, kind: kind, value: value, limit: limit,
                    window: .calendarMonth, resetsAt: resetsAt, label: label)
            ])
    }

    private func unavailable(_ provider: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: nil, observedAt: now,
            status: .unavailable("network"), metrics: [])
    }

    // MARK: - Splitting

    /// Claude accounts and metered services are drawn completely differently — big
    /// percentages with a forecast versus a dense list — so the split has to happen once,
    /// here, rather than in each layout.
    func testClaudeAccountsAndServicesAreSeparated() {
        let model = TelemetryModel.build(
            snapshots: [
                snapshot("claude", account: "Claude Two"),
                snapshot("stripe"),
                snapshot("claude", account: "Claude"),
            ], now: now)

        XCTAssertEqual(model.claude.map(\.name), ["Claude", "Claude Two"])
        XCTAssertEqual(model.services.map(\.name), ["stripe"])
    }

    /// Sorting by usage would reshuffle every panel on every sample, and a list whose rows
    /// move cannot be read at a glance. The two places that rank do it at the point of use.
    func testOrderIsByNameAndDoesNotFollowUsage() {
        let model = TelemetryModel.build(
            snapshots: [
                snapshot("zulip", value: 99),
                snapshot("apollo", value: 1),
                snapshot("mux", value: 50),
            ], now: now)
        XCTAssertEqual(model.services.map(\.name), ["apollo", "mux", "zulip"])
    }

    // MARK: - Interpretation

    func testAFailedProviderKeepsItsRowAndSaysSoInWords() {
        let model = TelemetryModel.build(snapshots: [unavailable("sentry")], now: now)
        let row = model.services[0]
        XCTAssertEqual(row.display, "no data")
        XCTAssertEqual(row.state, .nodata)
        XCTAssertNil(row.utilization, "No reading means no bar — a zero bar would be a lie.")
    }

    func testAnUncappedMetricShowsItsValueRatherThanAPercentage() {
        let model = TelemetryModel.build(
            snapshots: [snapshot("stripe", value: 98_000, limit: nil, kind: .currency)],
            now: now)
        XCTAssertEqual(model.services[0].display, "$98,000")
        XCTAssertEqual(model.services[0].state, .uncapped)
        XCTAssertNil(model.services[0].utilization)
    }

    func testAnOverageIsReportedUnclamped() {
        let model = TelemetryModel.build(
            snapshots: [snapshot("firecrawl", value: 104, limit: 100)], now: now)
        XCTAssertEqual(model.services[0].display, "104%")
        XCTAssertEqual(model.services[0].state, .over)
    }

    // MARK: - Staleness

    func testAStaleReadingCarriesAQuestionMark() {
        let old = now.addingTimeInterval(-Thresholds.staleAfter - 1)
        let model = TelemetryModel.build(
            snapshots: [snapshot("github", value: 61, observedAt: old)], now: now)
        XCTAssertTrue(model.services[0].isStale)
        XCTAssertEqual(model.services[0].display, "61%?")
    }

    func testAReadingJustInsideTheWindowIsNotMarked() {
        let recent = now.addingTimeInterval(-Thresholds.staleAfter + 1)
        let model = TelemetryModel.build(
            snapshots: [snapshot("github", value: 61, observedAt: recent)], now: now)
        XCTAssertFalse(model.services[0].isStale)
        XCTAssertEqual(model.services[0].display, "61%")
    }

    /// ClaudeUsage stamps `.distantPast` when it cannot parse a profile. That must read as
    /// very stale, not crash and not read as fresh.
    func testADistantPastReadingIsStaleRatherThanFatal() {
        let model = TelemetryModel.build(
            snapshots: [snapshot("claude", account: "Claude", observedAt: .distantPast)],
            now: now)
        XCTAssertTrue(model.claude[0].isStale)
    }

    // MARK: - Attention

    /// Quiet is the usual state, and that is what makes the loud one mean something.
    func testTheDesktopStaysQuietUntilSomethingIsActuallyNearItsLimit() {
        let calm = TelemetryModel.build(
            snapshots: [snapshot("a", value: 79), snapshot("b", value: 12)], now: now)
        XCTAssertEqual(calm.attention, .quiet)

        let hot = TelemetryModel.build(
            snapshots: [snapshot("a", value: 80), snapshot("b", value: 12)], now: now)
        XCTAssertEqual(hot.attention, .alert)
    }

    func testNothingReportingIsQuietRatherThanAlarming() {
        let model = TelemetryModel.build(snapshots: [unavailable("a")], now: now)
        XCTAssertEqual(
            model.attention, .quiet,
            "An outage in our own collection must not paint the desktop red.")
    }

    // MARK: - Renewals

    func testRenewalsAreOrderedAndBoundedToTheAxisTheCardDraws() {
        let model = TelemetryModel.build(
            snapshots: [
                snapshot("twilio", resetsAt: now.addingTimeInterval(11 * 86400)),
                snapshot("vercel", resetsAt: now.addingTimeInterval(3 * 86400)),
                snapshot("later", resetsAt: now.addingTimeInterval(60 * 86400)),
                snapshot("past", resetsAt: now.addingTimeInterval(-86400)),
                snapshot("none"),
            ], now: now)

        XCTAssertEqual(model.renewals.map(\.name), ["vercel", "twilio"])
        XCTAssertEqual(model.renewals.map(\.daysAway), [3, 11])
    }

    // MARK: - Sparklines

    func testASparklineIsEmptyUntilThereIsATrendToDraw() {
        let model = TelemetryModel.build(
            snapshots: [snapshot("github")], history: ["github": [42]], now: now)
        // One point is not a trend. The layout refuses to draw it — a flat line is a claim
        // about data we do not have, the same rule the forecast already follows.
        XCTAssertEqual(model.services[0].sparkline, [42])
        XCTAssertLessThan(model.services[0].sparkline.count, 2)
    }

    func testHistoryIsMatchedByRowNameSoAccountsKeepTheirOwnSeries() {
        let model = TelemetryModel.build(
            snapshots: [snapshot("github", account: "acme")],
            history: ["acme": [1, 2, 3]], now: now)
        XCTAssertEqual(model.services[0].sparkline, [1, 2, 3])
    }

    // MARK: - Golden

    /// The model is the golden-file format, not the SVG.
    ///
    /// A full-document SVG golden across three layouts and two attention states is a
    /// maintenance tax that teaches people to re-record without reading the diff. This
    /// catches every content regression — a wrong row, a lost order, a missing `?`, a
    /// misclassified state — in something a person can read, and does not move when pure
    /// geometry changes.
    func testTheModelMatchesItsGolden() throws {
        let model = TelemetryModel.build(
            snapshots: [
                snapshot(
                    "claude", account: "Claude Two", value: 62, limit: nil,
                    kind: .percentOfLimit, key: "five_hour", label: "5-hour"),
                snapshot("stripe", value: 98_000, limit: nil, kind: .currency),
                snapshot("github", value: 4_900, limit: 5_000, key: "rate_core"),
                unavailable("sentry"),
            ],
            history: ["github": [10, 20, 30]],
            now: now,
            // Explicit, because the model carries its zone and the golden encodes it. Left
            // to default to `.current` this file would pass on the machine that recorded it
            // and fail everywhere else — which is precisely the bug that putting the zone in
            // the model was meant to end, reappearing in the test for it.
            timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = String(data: try encoder.encode(model), encoding: .utf8)!

        XCTAssertEqual(json, Self.golden)
    }

    private static let golden = """
        {
          "attention" : "alert",
          "claude" : [
            {
              "display" : "62%",
              "isStale" : false,
              "name" : "Claude Two",
              "state" : "ok",
              "utilization" : 62,
              "windowLabel" : "5-hour"
            }
          ],
          "generatedAt" : 1784000000,
          "renewals" : [

          ],
          "services" : [
            {
              "display" : "98%",
              "isStale" : false,
              "name" : "github",
              "sparkline" : [
                10,
                20,
                30
              ],
              "state" : "warn",
              "utilization" : 98
            },
            {
              "display" : "no data",
              "isStale" : false,
              "name" : "sentry",
              "sparkline" : [

              ],
              "state" : "nodata"
            },
            {
              "display" : "$98,000",
              "isStale" : false,
              "name" : "stripe",
              "sparkline" : [

              ],
              "state" : "uncapped"
            }
          ],
          "timeZone" : {
            "identifier" : "GMT"
          }
        }
        """
}
