import XCTest

@testable import TMUDesign

final class UsageStateTests: XCTestCase {

    /// These are keys in `web/widgets.json`, which `check-generated.sh` byte-compares. The
    /// wallpaper emitted them as SVG CSS classes; that renderer is gone and the constraint
    /// outlived it. Renaming a case silently rewrites a committed artifact.
    func testTheRawValuesAreWhatTheGeneratedModelsAreKeyedOn() {
        XCTAssertEqual(
            UsageState.allCases.map(\.rawValue),
            ["ok", "warn", "over", "nodata", "uncapped"])
    }

    func testTheBoundariesAreInclusiveAtTheThreshold() {
        XCTAssertEqual(UsageState.classify(utilization: 79.99), .ok)
        XCTAssertEqual(UsageState.classify(utilization: 80), .warn)
        XCTAssertEqual(UsageState.classify(utilization: 99.99), .warn)
        XCTAssertEqual(UsageState.classify(utilization: 100), .over)
    }

    /// Readings are never clamped. An account at 104% of its limit is a real thing that
    /// happens, and rounding it down to 100 would hide the overage.
    func testAnOverageStaysOver() {
        XCTAssertEqual(UsageState.classify(utilization: 1040), .over)
    }

    /// `uncapped` and `nodata` must stay distinct. A provider reporting revenue has a
    /// perfectly good number and simply no ceiling; calling that "no data" hides a figure
    /// we have.
    func testUncappedAndNodataAreDifferentInks() {
        XCTAssertNotEqual(UsageState.uncapped.ink, UsageState.nodata.ink)
    }
}

final class InkTests: XCTestCase {

    /// Pinned against the design handoff. These are not arbitrary: warn and over in
    /// particular are read at a glance from across a room, and a "tidier" green would
    /// change what the widget communicates.
    func testThePaletteMatchesTheHandoff() {
        XCTAssertEqual(Ink.scrim.value, "#0c1216")
        XCTAssertEqual(Ink.primary.value, "#eaf0f2")
        XCTAssertEqual(Ink.muted.value, "#8b979e")
        XCTAssertEqual(Ink.absent.value, "#5b686f")
        XCTAssertEqual(Ink.ok.value, "#4e8f78")
        XCTAssertEqual(Ink.warn.value, "#e0a24a")
        XCTAssertEqual(Ink.over.value, "#e2564a")
        XCTAssertEqual(Ink.window.value, "#1e2429")
        XCTAssertEqual(Ink.titlebar.value, "#262c31")
        XCTAssertEqual(Ink.popover.value, "#1d2226")
        XCTAssertEqual(Ink.action.value, "#3f6df0")
    }

    func testComponentsAreParsedForConsumersThatCannotUseHex() {
        // #4e8f78 -> 78/255, 143/255, 120/255. SwiftUI needs these; the SVG never does.
        XCTAssertEqual(Ink.ok.red, 78 / 255, accuracy: 0.0001)
        XCTAssertEqual(Ink.ok.green, 143 / 255, accuracy: 0.0001)
        XCTAssertEqual(Ink.ok.blue, 120 / 255, accuracy: 0.0001)
    }

    func testWhiteRoundTrips() {
        XCTAssertEqual(Ink.track.red, 1)
        XCTAssertEqual(Ink.track.green, 1)
        XCTAssertEqual(Ink.track.blue, 1)
    }
}

final class FreshnessTests: XCTestCase {

    func testAReadingIsFreshRightUpToTheThreshold() {
        XCTAssertFalse(Freshness.isStale(age: Thresholds.staleAfter - 1))
        XCTAssertTrue(Freshness.isStale(age: Thresholds.staleAfter))
    }

    func testTheQuestionMarkIsOnlyAddedWhenStale() {
        XCTAssertEqual(Freshness.mark("62%", stale: false), "62%")
        XCTAssertEqual(Freshness.mark("62%", stale: true), "62%?")
    }

    /// A stale reading keeps its state — a stale 96% is still alarming — but is drawn muted.
    /// Showing it in full red claims a certainty about right now that we do not have.
    func testAStaleReadingIsMutedRatherThanRecoloured() {
        XCTAssertEqual(Freshness.ink(for: .over, stale: false), Ink.over)
        XCTAssertEqual(Freshness.ink(for: .over, stale: true), Ink.muted)
    }

    /// The three horizons answer different questions and must not be collapsed. Thirty
    /// minutes everywhere would stop every weekly metric being forecast, because a weekly
    /// reading two hours old is perfectly good for fitting a slope.
    func testTheDisplayRuleIsThirtyMinutesAndSaysSoInOnePlace() {
        XCTAssertEqual(Thresholds.staleAfter, 30 * 60)
    }
}
