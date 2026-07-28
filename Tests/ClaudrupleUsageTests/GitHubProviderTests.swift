import Foundation
import XCTest

@testable import ClaudrupleUsage

final class GitHubProviderTests: XCTestCase {

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

    private var fixtures: ProviderConformance.Fixtures {
        .init(success: [GitHubProvider.rateLimitEndpoint: Self.recorded])
    }

    // MARK: - Conformance

    func testItConformsToTheAdapterContract() async {
        await ProviderConformance.assertConformance(
            { GitHubProvider(http: $0) }, fixtures: fixtures)
    }

    // MARK: - Mapping

    func testUsedAndLimitBecomeUtilisation() async throws {
        let snapshot = try await snapshot()
        let core = try XCTUnwrap(snapshot.metrics.first { $0.key == "rate_core" })

        XCTAssertEqual(core.value, 100)
        XCTAssertEqual(core.limit, 5000)
        XCTAssertEqual(try XCTUnwrap(core.utilization), 2, accuracy: 0.001)
    }

    func testTheResetTimeIsCarriedThroughAsADate() async throws {
        // Reported by the API as epoch seconds, and worth keeping: it is the only provider
        // detail that says when headroom comes back.
        let snapshot = try await snapshot()
        let core = try XCTUnwrap(snapshot.metrics.first { $0.key == "rate_core" })

        XCTAssertEqual(core.resetsAt, Date(timeIntervalSince1970: 1_785_151_794))
    }

    func testSearchAndGraphQLAreReportedSeparately() async throws {
        // They have their own quotas and their own windows — search resets every minute
        // while core resets hourly, so folding them together would misreport both.
        let snapshot = try await snapshot()

        XCTAssertEqual(snapshot.metrics.first { $0.key == "rate_search" }?.limit, 30)
        XCTAssertEqual(snapshot.metrics.first { $0.key == "rate_graphql" }?.limit, 5000)
        XCTAssertEqual(
            snapshot.metrics.first { $0.key == "rate_search" }?.window, .rolling(60))
        XCTAssertEqual(
            snapshot.metrics.first { $0.key == "rate_core" }?.window, .rolling(3600))
    }

    func testTheBindingLimitIsWhicheverIsNearestItsCap() async throws {
        // search is 9/30 = 30%, core is 100/5000 = 2%.
        let snapshot = try await snapshot()

        XCTAssertEqual(snapshot.binding?.key, "rate_search")
    }

    func testAResourceMissingFromTheResponseIsSkippedRatherThanZeroed() async throws {
        // GitHub returns different resource sets for different token types. A resource that
        // is absent is unknown, and reporting it as 0% would read as unlimited headroom.
        let client = FixtureHTTPClient(json: [
            GitHubProvider.rateLimitEndpoint:
                #"{"resources":{"core":{"limit":5000,"remaining":4900,"reset":1785151794,"used":100}}}"#
        ])
        let snapshot = try await self.snapshot(client: client)

        XCTAssertEqual(snapshot.metrics.map(\.key), ["rate_core"])
    }

    func testTheTokenIsSentAsABearerHeader() async throws {
        let client = FixtureHTTPClient(json: [GitHubProvider.rateLimitEndpoint: Self.recorded])
        _ = try await snapshot(client: client)

        let request = try XCTUnwrap(client.recordedRequests.all.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer gh_test_token")
        XCTAssertEqual(
            request.headers["X-GitHub-Api-Version"], "2022-11-28",
            "pinning the API version stops a future default from reshaping the response")
    }

    // MARK: -

    private func snapshot(client: FixtureHTTPClient? = nil) async throws -> UsageSnapshot {
        let http =
            client ?? FixtureHTTPClient(json: [GitHubProvider.rateLimitEndpoint: Self.recorded])
        let store = MutableCredentials()
        try store.set("gh_test_token", for: "github")
        return await GitHubProvider(http: http).snapshot(credentials: store, now: now)
    }
}
