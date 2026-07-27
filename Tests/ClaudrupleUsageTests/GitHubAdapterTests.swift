import Foundation
import XCTest

@testable import ClaudrupleUsage

final class GitHubAdapterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_148_000)

    /// Recorded from a live call to https://api.github.com/rate_limit on 2026-07-27, and
    /// matching the schema in the REST documentation. Trimmed to the resources the adapter
    /// reads; the real payload carries several more.
    private static let recorded = #"""
        {
          "resources": {
            "core":   { "limit": 5000, "remaining": 4900, "reset": 1785151794, "used": 100 },
            "search": { "limit": 30,   "remaining": 21,   "reset": 1785148254, "used": 9 },
            "graphql":{ "limit": 5000, "remaining": 5000, "reset": 1785151794, "used": 0 }
          },
          "rate": { "limit": 5000, "remaining": 4900, "reset": 1785151794, "used": 100 }
        }
        """#

    func testItConformsToTheAdapterContract() async {
        await ProviderConformance.assertConformance(
            GitHubAdapter(), fixtures: .init(success: Self.recorded))
    }

    // MARK: - Mapping

    private func parsed() throws -> ProviderSnapshot {
        try GitHubAdapter().parse(Data(Self.recorded.utf8), now: now)
    }

    func testUsedAndLimitBecomeUtilisation() throws {
        let core = try XCTUnwrap(parsed().metrics.first { $0.key == "rate_core" })

        XCTAssertEqual(core.value, 100)
        XCTAssertEqual(core.limit, 5000)
        XCTAssertEqual(try XCTUnwrap(core.utilization), 2, accuracy: 0.001)
    }

    func testTheResetTimeIsCarriedThroughAsADate() throws {
        // Reported by the API as epoch seconds, and worth keeping: it is the only detail
        // that says when headroom comes back.
        let core = try XCTUnwrap(parsed().metrics.first { $0.key == "rate_core" })

        XCTAssertEqual(core.resetsAt, Date(timeIntervalSince1970: 1_785_151_794))
    }

    func testSearchAndGraphQLKeepTheirOwnWindows() throws {
        // Search resets every minute while core resets hourly, so folding them together
        // would misreport both.
        let snapshot = try parsed()

        XCTAssertEqual(snapshot.metrics.first { $0.key == "rate_search" }?.window, .rolling(60))
        XCTAssertEqual(snapshot.metrics.first { $0.key == "rate_core" }?.window, .rolling(3600))
    }

    func testTheBindingLimitIsWhicheverIsNearestItsCap() throws {
        // search is 9/30 = 30%, core is 100/5000 = 2%.
        XCTAssertEqual(try parsed().binding?.key, "rate_search")
    }

    func testAResourceMissingFromTheResponseIsSkippedRatherThanZeroed() throws {
        // GitHub returns different resource sets for different token types. An absent
        // resource is unknown, and reporting it as 0% would read as unlimited headroom.
        let partial = #"{"resources":{"core":{"limit":5000,"remaining":4900,"reset":1785151794,"used":100}}}"#
        let snapshot = try GitHubAdapter().parse(Data(partial.utf8), now: now)

        XCTAssertEqual(snapshot.metrics.map(\.key), ["rate_core"])
    }

    func testAResponseWithNoRecognisedResourcesIsAnErrorNotAnEmptyReading() {
        // An empty metric list would render as a healthy provider with nothing to report.
        XCTAssertThrowsError(
            try GitHubAdapter().parse(Data(#"{"resources":{}}"#.utf8), now: now))
    }

    func testTheTokenIsSentAsABearerHeaderWithAPinnedAPIVersion() throws {
        let request = try GitHubAdapter().request(credential: "gh_test_token")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gh_test_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertFalse(request.url?.absoluteString.contains("gh_test_token") ?? true)
    }
}
