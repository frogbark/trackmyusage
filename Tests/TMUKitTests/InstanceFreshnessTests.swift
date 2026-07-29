import Foundation
import XCTest

@testable import TMUKit

/// Clones do not update themselves, and nothing used to say so. These pin the reporting,
/// because every one of them is a case where saying the wrong thing is worse than saying
/// nothing: a clone wrongly called current never gets refreshed, and one wrongly called
/// stale sends someone through a re-clone they did not need.
final class InstanceFreshnessTests: XCTestCase {

    /// Prevents: the ordinary case regressing while the edge cases get all the attention.
    func testAMatchingVersionIsCurrent() {
        XCTAssertEqual(
            InstanceFreshness.compare(clone: "0.16.1", installed: "0.16.1"), .current)
    }

    /// Prevents: a clone left on an old build with nothing on screen to say so.
    func testADifferentVersionIsStaleAndCarriesBothSides() {
        XCTAssertEqual(
            InstanceFreshness.compare(clone: "0.15.9", installed: "0.16.1"),
            .stale(clone: "0.15.9", installed: "0.16.1"))
    }

    /// Prevents: reporting "up to date" about a clone whose version nobody could read.
    ///
    /// A missing reading is not a passing one — the same rule the wallpaper follows when it
    /// draws "no data" rather than zero.
    func testAMissingVersionOnEitherSideIsUnknownRatherThanCurrent() {
        XCTAssertEqual(InstanceFreshness.compare(clone: nil, installed: "0.16.1"), .unknown)
        XCTAssertEqual(InstanceFreshness.compare(clone: "0.16.1", installed: nil), .unknown)
        XCTAssertEqual(InstanceFreshness.compare(clone: nil, installed: nil), .unknown)
    }

    /// Prevents: an empty string reading as a version and comparing equal to another empty
    /// one, which would report two unreadable bundles as a matched pair.
    func testAnEmptyVersionIsTreatedAsMissing() {
        XCTAssertEqual(InstanceFreshness.compare(clone: "", installed: ""), .unknown)
        XCTAssertEqual(InstanceFreshness.compare(clone: "", installed: "0.16.1"), .unknown)
    }

    /// Prevents: a downgrade being reported as fine.
    ///
    /// If Claude is reinstalled at an older build, the clone is now the newer of the two and
    /// an ordering comparison would call that "up to date". It is not: the clone no longer
    /// matches what is installed, and the remedy — re-clone from what is there now — is the
    /// same one the upgrade case needs.
    func testACloneNewerThanTheInstalledClaudeIsStillStale() {
        XCTAssertEqual(
            InstanceFreshness.compare(clone: "0.17.0", installed: "0.16.1"),
            .stale(clone: "0.17.0", installed: "0.16.1"))
    }

    /// Prevents: a version string that is not dotted numbers falling into a parser's
    /// default. Equality has no parser to fall out of.
    func testAnUnusuallyShapedVersionStillComparesByEquality() {
        XCTAssertEqual(
            InstanceFreshness.compare(clone: "2026.7-nightly", installed: "2026.7-nightly"),
            .current)
        XCTAssertEqual(
            InstanceFreshness.compare(clone: "2026.7-nightly", installed: "2026.8-nightly"),
            .stale(clone: "2026.7-nightly", installed: "2026.8-nightly"))
    }

    /// Prevents: `needsRefresh` drifting so that unknown starts prompting a re-clone.
    ///
    /// Only `stale` is actionable. Refreshing on `unknown` would re-sign a bundle on the
    /// strength of a reading that was never taken.
    func testOnlyStaleAsksForAnything() {
        XCTAssertTrue(InstanceFreshness.stale(clone: "a", installed: "b").needsRefresh)
        XCTAssertFalse(InstanceFreshness.current.needsRefresh)
        XCTAssertFalse(InstanceFreshness.unknown.needsRefresh)
    }

    // MARK: - Across a set of instances

    /// Prevents: the primary appearing in the list as a permanent "up to date" row, and
    /// worse, being offered for refresh — TrackMyUsage never modifies /Applications/Claude.app.
    func testThePrimaryIsTheReferenceAndNeverAppearsAsAResult() {
        let found =
            [instance("Claude", version: "0.16.1", primary: true)]
            + [instance("Work", version: "0.16.1"), instance("Personal", version: "0.15.9")]

        XCTAssertEqual(found.installedClaudeVersion, "0.16.1")
        XCTAssertEqual(found.freshness().map(\.instance.name), ["Work", "Personal"])
        XCTAssertEqual(found.needingRefresh.map(\.name), ["Personal"])
    }

    /// Prevents: every clone being reported stale because Claude itself is missing.
    ///
    /// With no primary there is nothing to compare against, and a listing that told someone
    /// to re-clone all four instances from an app that is not installed would be actively
    /// harmful advice.
    func testWithNoInstalledClaudeNothingIsCalledStale() {
        let found = [instance("Work", version: "0.16.1"), instance("Personal", version: "0.9.0")]

        XCTAssertNil(found.installedClaudeVersion)
        XCTAssertTrue(found.needingRefresh.isEmpty)
        XCTAssertEqual(found.freshness().map(\.freshness), [.unknown, .unknown])
    }

    // MARK: - Fixtures

    private func instance(_ name: String, version: String?, primary: Bool = false)
        -> DiscoveredInstance
    {
        DiscoveredInstance(
            name: name,
            bundleID: primary
                ? InstanceLocator.primaryBundleID
                : "\(InstanceLocator.claudeBundlePrefix).\(LegacyNames.instanceBundleInfix)"
                    + ".\(name.lowercased())",
            appURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            profileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            isPrimary: primary,
            version: version)
    }
}
