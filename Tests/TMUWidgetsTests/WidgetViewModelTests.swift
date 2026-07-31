import TMUDesign
import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMUWidgets

final class WidgetViewModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Staleness

    /// The whole point of the multi-entry timeline. The same published model, rendered for a
    /// moment past the freshness threshold, must come out stale — because that render happens
    /// on the system's clock inside a widget whose publisher has died, and nothing will be
    /// there to recompute it. If staleness read the wall clock instead of `at`, a frozen
    /// widget would show a stale number with no `?` forever.
    func testTheSameModelRenderedLaterIsStaleWithoutAnythingRepublishingIt() {
        let model = Fixtures.model(at: now)

        let fresh = WidgetViewModel.make(from: model, family: .medium, at: now)
        XCTAssertFalse(fresh.isStale)
        XCTAssertFalse(fresh.rows[0].display.hasSuffix("?"))

        let later = now.addingTimeInterval(Thresholds.staleAfter + 1)
        let aged = WidgetViewModel.make(from: model, family: .medium, at: later)
        XCTAssertTrue(aged.isStale)
        XCTAssertTrue(aged.rows[0].display.hasSuffix("?"))
    }

    /// A row that was already stale must not be marked twice. `Freshness.mark` appends
    /// unconditionally, so marking an already-marked row yields "62%??" — which a reader takes
    /// for a rendering fault rather than for staleness, and which would silently change every
    /// golden.
    func testARowThatWasAlreadyStaleIsNotMarkedTwice() {
        // Observed long ago, so TelemetryModel marks the row stale on its own.
        let model = Fixtures.model(at: now, observedAt: now.addingTimeInterval(-7200))
        let later = now.addingTimeInterval(Thresholds.staleAfter + 1)

        let aged = WidgetViewModel.make(from: model, family: .medium, at: later)
        for row in aged.rows {
            XCTAssertFalse(row.display.hasSuffix("??"), "double-marked: \(row.display)")
        }
    }

    // MARK: - Absence

    /// "Absence is stated, never drawn as zero." An empty model must say so rather than
    /// render a blank panel, which reads as a broken app, or a 0%, which is a lie.
    func testAModelWithNoReadingsStatesItsAbsenceRatherThanDrawingNothing() {
        let empty = TelemetryModel.build(snapshots: [], now: now, timeZone: .gmt)
        let vm = WidgetViewModel.make(from: empty, family: .large, at: now)

        XCTAssertEqual(vm.emptyReason, "no data")
        XCTAssertNil(vm.headline)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    /// A reading with no ceiling has no bar. A bar is a claim about proximity to a limit, and
    /// drawing one at zero for an uncapped counter invents a limit that does not exist.
    func testAnUncappedReadingCarriesNoUtilisationSoNoBarCanBeDrawn() {
        // Nothing measurable in the model, so the uncapped reading is necessarily the
        // headline. With a capped row present it would rightly lose, which is the next test.
        let model = Fixtures.model(at: now, utilizations: [], uncapped: true)
        let vm = WidgetViewModel.make(from: model, family: .large, at: now)

        XCTAssertNotNil(vm.headline)
        XCTAssertNil(vm.headline?.utilization)
    }

    // MARK: - Overflow

    /// Truncation must be reported. A widget showing three of nine accounts while looking
    /// like it shows all of them is worse than one that admits it — the reader draws a
    /// conclusion about accounts they cannot see.
    func testRowsBeyondTheFamilyBudgetAreReportedRatherThanSilentlyDropped() {
        let model = Fixtures.model(at: now, accountCount: 9)
        let vm = WidgetViewModel.make(from: model, family: .medium, at: now)

        XCTAssertEqual(vm.rows.count, WidgetFamilyID.medium.rowBudget)
        XCTAssertEqual(vm.overflow, 9 - WidgetFamilyID.medium.rowBudget)
    }

    func testAFamilyThatFitsEverythingReportsNoOverflow() {
        let model = Fixtures.model(at: now, accountCount: 2)
        let vm = WidgetViewModel.make(from: model, family: .medium, at: now)
        XCTAssertEqual(vm.overflow, 0)
    }

    // MARK: - Headline

    /// A glance must land on the reading that matters. Ranking by name or by arrival order
    /// would put a 4% account above a 97% one and make the small widget actively misleading.
    func testTheHeadlineIsTheHighestUtilisationNotTheFirstRow() {
        let model = Fixtures.model(at: now, utilizations: [12, 97, 40])
        let vm = WidgetViewModel.make(from: model, family: .small, at: now)

        XCTAssertEqual(vm.headline?.utilization, 97)
    }

    /// An uncapped counter is not "less urgent" than 12% — it is not on that scale at all.
    /// Ranking the two together would need a number for the unmeasurable one, and any number
    /// chosen would be invented.
    func testAnUnmeasurableReadingIsOnlyTheHeadlineWhenNothingMeasurableExists() {
        let mixed = Fixtures.model(at: now, utilizations: [12], uncapped: true)
        XCTAssertEqual(
            WidgetViewModel.make(from: mixed, family: .small, at: now).headline?.utilization, 12)

        let onlyUncapped = Fixtures.model(at: now, utilizations: [], uncapped: true)
        XCTAssertNotNil(WidgetViewModel.make(from: onlyUncapped, family: .small, at: now).headline)
    }

    // MARK: - Family shape

    /// The small widget is its headline. Giving it rows as well would put four points of type
    /// in 170 points of space and read as neither a summary nor a list.
    func testTheSmallFamilyCarriesAHeadlineAndNoRows() {
        let model = Fixtures.model(at: now, accountCount: 4)
        let vm = WidgetViewModel.make(from: model, family: .small, at: now)

        XCTAssertNotNil(vm.headline)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    /// Renewals are a large-widget concern. A medium has no room for the axis and would drop
    /// it in the view — where the goldens could not see the difference.
    func testOnlyTheLargeFamilyCarriesRenewals() {
        let model = Fixtures.model(at: now, withRenewal: true)

        XCTAssertTrue(WidgetViewModel.make(from: model, family: .small, at: now).renewals.isEmpty)
        XCTAssertTrue(WidgetViewModel.make(from: model, family: .medium, at: now).renewals.isEmpty)
        XCTAssertFalse(WidgetViewModel.make(from: model, family: .large, at: now).renewals.isEmpty)
    }

    // MARK: - Purity

    /// The property that makes web/widgets.json a usable check: identical inputs must produce
    /// an identical value, so a diff there means the code changed rather than the clock did.
    func testTheSameInputsProduceAnIdenticalModel() {
        let model = Fixtures.model(at: now)
        for family in WidgetFamilyID.allCases {
            XCTAssertEqual(
                WidgetViewModel.make(from: model, family: family, at: now),
                WidgetViewModel.make(from: model, family: family, at: now))
        }
    }

    /// It is the golden-file format, so it has to survive a round trip. A model that encodes
    /// but does not decode would fail in the widget rather than in this suite.
    func testTheModelRoundTripsThroughJSON() throws {
        let vm = WidgetViewModel.make(from: Fixtures.model(at: now), family: .large, at: now)
        let data = try JSONEncoder().encode(vm)
        XCTAssertEqual(try JSONDecoder().decode(WidgetViewModel.self, from: data), vm)
    }
}

// MARK: - Fixtures

private enum Fixtures {

    static func model(
        at now: Date,
        observedAt: Date? = nil,
        accountCount: Int = 2,
        utilizations: [Double]? = nil,
        uncapped: Bool = false,
        withRenewal: Bool = false
    ) -> TelemetryModel {
        let values = utilizations ?? Array(repeating: 42, count: accountCount)
        var snapshots: [UsageSnapshot] = values.enumerated().map { index, value in
            capped(
                account: "acct-\(index)", utilization: value,
                observedAt: observedAt ?? now,
                resetsAt: withRenewal ? now.addingTimeInterval(3 * 86400) : nil)
        }
        if uncapped {
            snapshots.append(uncappedSnapshot(observedAt: observedAt ?? now))
        }
        return TelemetryModel.build(snapshots: snapshots, now: now, timeZone: .gmt)
    }

    /// Nineteen services whose utilisations run the other way from their names, so that
    /// name-order truncation and urgency-order truncation cannot both be right.
    static func spread(at now: Date) -> TelemetryModel {
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "zulu"]
        let snapshots = names.enumerated().map { index, name in
            service(name: name, utilization: Double(2 + index * 15), observedAt: now)
        }
        return TelemetryModel.build(snapshots: snapshots, now: now, timeZone: .gmt)
    }

    private static func service(name: String, utilization: Double, observedAt: Date)
        -> UsageSnapshot
    {
        UsageSnapshot(
            provider: name, account: name, observedAt: observedAt, status: .ok,
            metrics: [
                Metric(
                    key: "quota", kind: .percentOfLimit, value: utilization, limit: 100,
                    window: .calendarMonth, resetsAt: nil, label: "Monthly")
            ])
    }

    private static func capped(
        account: String, utilization: Double, observedAt: Date, resetsAt: Date?
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: "claude",
            account: account,
            observedAt: observedAt,
            status: .ok,
            metrics: [
                Metric(
                    key: "five-hour", kind: .percentOfLimit, value: utilization, limit: 100,
                    window: .rolling(5 * 3600), resetsAt: resetsAt, label: "5-hour")
            ])
    }

    private static func uncappedSnapshot(observedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: "meter",
            account: "meter",
            observedAt: observedAt,
            status: .ok,
            metrics: [
                Metric(
                    key: "requests", kind: .count, value: 1234, limit: nil,
                    window: .none, resetsAt: nil, label: "Requests")
            ])
    }
}

// MARK: - Truncation picks the right rows

extension WidgetViewModelTests {

    /// The bug this prevents was visible in a render: nineteen readings truncated to six by
    /// name, hiding a provider over its limit behind "+13 more" — while the small family
    /// showed that same reading as its headline. A truncated view that drops the worst row is
    /// worse than no view, because it looks complete.
    func testTruncationKeepsTheMostUrgentRowsRatherThanTheAlphabeticallyFirst() {
        let model = Fixtures.spread(at: now)
        let vm = WidgetViewModel.make(from: model, family: .large, at: now)

        let shown = Set(vm.rows.map(\.name))
        XCTAssertTrue(shown.contains("zulu"), "the 104% reading must survive truncation")
        XCTAssertFalse(shown.contains("alpha"), "a 2% reading must not displace it")
    }

    /// Chosen by urgency, drawn by name. Ranking the visible list too would reshuffle rows on
    /// every sample and cost exactly the glanceability the name order exists to protect.
    func testTheRowsThatSurviveAreStillDrawnInNameOrder() {
        let model = Fixtures.spread(at: now)
        let vm = WidgetViewModel.make(from: model, family: .large, at: now)

        XCTAssertEqual(vm.rows.map(\.name), vm.rows.map(\.name).sorted())
    }
}

// MARK: - Encoding stability

extension WidgetViewModelTests {

    /// web/widgets.json is byte-compared by check-generated.sh, and a plain JSONEncoder emits
    /// keys in dictionary order. Swift seeds its hasher per process, so that order is often
    /// steady *within* a run and differs *between* runs — which is the axis that matters here,
    /// because CI regenerates the file in a different process from the one that committed it.
    /// Unsorted keys would fail for a reason no commit could fix, inviting a "fix" that
    /// excludes the file and quietly destroys the guarantee it provides.
    ///
    /// The cross-process half cannot be asserted from inside one process; check-generated.sh
    /// covers it by construction. This covers the rest.
    func testTheCanonicalEncodingIsByteStableAcrossCalls() throws {
        let vm = WidgetViewModel.make(from: Fixtures.model(at: now), family: .large, at: now)

        let first = try CanonicalJSON.encode(vm)
        for _ in 0..<20 {
            XCTAssertEqual(try CanonicalJSON.encode(vm), first)
        }
    }

}
