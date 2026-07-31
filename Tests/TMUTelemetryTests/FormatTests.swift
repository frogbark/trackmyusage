import Foundation
import TMUProviders
import XCTest

@testable import TMUTelemetry

/// The clock on the widget, and the zone it is read in.
///
/// This used to read `TimeZone.current`, which made the renderer a function of its inputs
/// and the machine — the same frozen instant drew 20:33 on a laptop and 03:33 on a UTC
/// runner, and the committed images disagreed with the ones CI regenerated.
final class FormatTimeZoneTests: XCTestCase {

    /// 2026-07-13 03:33 UTC.
    private let instant = Date(timeIntervalSince1970: 1_784_000_000)

    /// Prevents: the zone parameter being accepted and ignored.
    ///
    /// Two zones, one instant, two different clocks. If the argument were dropped and
    /// `.current` read instead, both would agree — and would agree differently depending on
    /// where the suite ran, which is the failure this replaced.
    func testTheZoneArgumentIsActuallyUsed() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        XCTAssertEqual(Format.time(instant, in: utc), "03:33")
        XCTAssertEqual(Format.time(instant, in: tokyo), "12:33")
        XCTAssertEqual(Format.time(instant, in: losAngeles), "20:33")
    }

    /// Prevents: a zone with a fractional offset being truncated to the hour.
    ///
    /// India is +05:30. An implementation that added whole hours would read 09:03 here and
    /// be right everywhere it was likely to be tested.
    func testAHalfHourOffsetIsHonoured() throws {
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertEqual(Format.time(instant, in: kolkata), "09:03")
    }

    /// Prevents: the model losing the zone it was built with.
    func testTheModelCarriesTheZoneItWasBuiltWith() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let model = TelemetryModel.build(snapshots: [], now: instant, timeZone: tokyo)
        XCTAssertEqual(model.timeZone, tokyo)
    }
}
