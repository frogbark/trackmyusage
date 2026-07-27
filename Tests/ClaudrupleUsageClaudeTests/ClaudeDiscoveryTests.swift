import ClaudrupleKit
import ClaudrupleUsage
import XCTest

@testable import ClaudrupleUsageClaude

final class ClaudeDiscoveryTests: XCTestCase {

    private var profile: URL!

    override func setUpWithError() throws {
        profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudruple-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: profile)
    }

    private func writeHistory(_ json: String) throws {
        try json.write(
            to: profile.appendingPathComponent("plan-usage-history.json"),
            atomically: true, encoding: .utf8)
    }

    // MARK: -

    func testReadsTheHistoryFileFromAProfileDirectory() throws {
        try writeHistory(
            """
            {"version":2,"samples":[
              {"t":1784000000000,"org":"o","u":{"fh":21,"sd":64}},
              {"t":1784000600000,"org":"o","u":{"fh":25,"sd":66}}]}
            """)

        let snapshot = ClaudeUsage.snapshot(
            name: "Work", bundleID: "com.example.work", profileURL: profile)

        XCTAssertTrue(snapshot.isReporting)
        XCTAssertEqual(snapshot.accountLabel, "Work")
        XCTAssertEqual(
            snapshot.binding?.key, "seven_day",
            "66 beats 25, so the weekly cap is what will stop work first")
    }

    func testAProfileWithNoHistoryFileIsUnavailable() {
        let snapshot = ClaudeUsage.snapshot(
            name: "Fresh", bundleID: "com.example.fresh", profileURL: profile)

        XCTAssertFalse(
            snapshot.isReporting,
            "an instance that has never run is a gap, not a reading of zero")
    }

    func testAMalformedHistoryFileIsUnavailableRatherThanFatal() throws {
        // The file is written by another process while we read it, so a torn or truncated
        // read is expected rather than exceptional. One bad file must not take out the
        // render for every other account.
        try writeHistory("{\"version\":2,\"samples\":[{\"t\":")

        let snapshot = ClaudeUsage.snapshot(
            name: "Torn", bundleID: "com.example.torn", profileURL: profile)

        XCTAssertFalse(snapshot.isReporting)
        if case .unavailable(let reason) = snapshot.status {
            XCTAssertFalse(reason.isEmpty, "the reason is worth surfacing")
        } else {
            XCTFail("expected unavailable, got \(snapshot.status)")
        }
    }
}
