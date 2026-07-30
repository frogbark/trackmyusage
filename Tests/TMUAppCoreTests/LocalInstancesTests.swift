import Foundation
import TMUKit
import TMUProviders
import XCTest

@testable import TMUAppCore

/// What the instances window is given to draw.
///
/// These run against real profile directories in a temp folder, because the bug they pin was
/// a `continue` on a file read: an instance whose `plan-usage-history.json` was missing left
/// the loop before it ever became a row. Nothing that tested rows in isolation could see it —
/// the rows were correct, there were simply fewer of them than there were instances.
final class LocalInstancesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Prevents: creating an instance, opening the window to look at it, and not finding it.
    ///
    /// This is the whole bug. An instance created an hour ago and not yet signed into has no
    /// history file, and was silently dropped from the one view whose subject is instances.
    func testAnInstanceWithNoHistoryStillAppears() throws {
        let instances = [
            try instance("Claude", primary: true, samples: 1),
            try instance("Fresh", samples: 0),
        ]
        let result = LocalInstances(discover: { instances }).read(now: Date())

        XCTAssertEqual(
            result.rows.map(\.name), ["Claude", "Fresh"],
            "an instance without usage history was dropped")
    }

    /// Prevents: the banner naming an instance the window cannot show.
    ///
    /// `outOfStepInstances` counts every discovered clone while rows counted only those with
    /// usage. A clone could be named as needing a re-clone in the popover and have no card in
    /// the window — which is where someone would go to act on it.
    func testEveryInstanceNamedAsOutOfStepHasARowToActOn() throws {
        let instances = [
            try instance("Claude", primary: true, samples: 1, version: "1.24012.9"),
            try instance("Stale", samples: 0, version: "1.24011.2"),
        ]
        let result = LocalInstances(discover: { instances }).read(now: Date())

        XCTAssertEqual(result.outOfStepInstances, ["Stale"])
        for named in result.outOfStepInstances {
            XCTAssertTrue(
                result.rows.contains { $0.name == named },
                "\(named) is named as out of step but has no row")
        }
    }

    /// Prevents: an instance with no readings being drawn as one at zero.
    ///
    /// The project's rule is that absence is stated and never drawn as zero. A row with no
    /// history must carry no metrics at all rather than a set of zeroed ones, and must say
    /// which of the two silences it is.
    func testAnInstanceWithNoHistoryReportsNoMetricsRatherThanZeroes() throws {
        let instances = [try instance("Fresh", samples: 0)]
        let row = try XCTUnwrap(
            LocalInstances(discover: { instances }).read(now: Date()).rows.first)

        XCTAssertTrue(row.metrics.isEmpty)
        XCTAssertFalse(row.hasReadings)
    }

    /// Prevents: an instance that does have history losing its readings in the restructure.
    func testAnInstanceWithHistoryStillReportsItsMetrics() throws {
        let instances = [try instance("Claude", primary: true, samples: 1)]
        let row = try XCTUnwrap(
            LocalInstances(discover: { instances }).read(now: Date()).rows.first)

        XCTAssertTrue(row.hasReadings)
        XCTAssertFalse(row.metrics.isEmpty, "a used instance reported no windowed metrics")
    }

    /// Prevents: an unused instance being counted as an account for steering.
    ///
    /// Rows and accounts are different questions. Steering recommends the account with
    /// headroom, and an instance nobody has signed into has no headroom — it has no data.
    /// Recommending a switch to it would be advice built from an absence.
    func testAnInstanceWithNoHistoryIsNotOfferedAsSomewhereToSwitchTo() throws {
        let instances = [
            try instance("Claude", primary: true, samples: 1),
            try instance("Fresh", samples: 0),
        ]
        let result = LocalInstances(discover: { instances }).read(now: Date())

        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(
            result.snapshots.count, 1,
            "an instance with no history became a usage snapshot")
    }

    // MARK: - Fixtures

    /// A discovered instance backed by a real profile directory.
    private func instance(
        _ name: String, primary: Bool = false, samples: Int, version: String = "1.24012.9"
    ) throws -> DiscoveredInstance {
        let profile = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        if samples > 0 {
            // The real schema: v2, millisecond timestamps, metrics nested under `u`. `fh` is
            // the five-hour window, chosen because it carries one — the row builder drops
            // metrics with no window, since a figure with no cap cannot be a percentage of
            // anything.
            let now = Date().timeIntervalSince1970 * 1000
            let entries = (0..<samples).map { index in
                #"{"t":\#(now - Double(index) * 3_600_000),"org":"test","u":{"fh":42}}"#
            }
            try #"{"version":2,"samples":[\#(entries.joined(separator: ","))]}"#.write(
                to: profile.appendingPathComponent("plan-usage-history.json"),
                atomically: true, encoding: .utf8)
        }

        return DiscoveredInstance(
            name: name,
            bundleID: primary
                ? InstanceLocator.primaryBundleID
                : "\(InstanceLocator.claudeBundlePrefix).\(LegacyNames.instanceBundleInfix)"
                    + ".\(name.lowercased())",
            appURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            profileURL: profile,
            isPrimary: primary,
            version: version)
    }
}
