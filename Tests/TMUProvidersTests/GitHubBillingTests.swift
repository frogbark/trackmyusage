import XCTest

@testable import TMUProviders

/// The billing half of the GitHub provider.
///
/// Two endpoints sit behind one provider because one token answers both. They measure
/// different things — `/rate_limit` is a quota that stops work now, billing is money
/// already spent — and the pairing only works if the optional half cannot damage the
/// mandatory one.
final class GitHubBillingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rateLimitURL = GitHubProvider.rateLimitEndpoint
    private let userBillingURL =
        "https://api.github.com/users/jmyers/settings/billing/usage"
    private let orgBillingURL =
        "https://api.github.com/organizations/acme/settings/billing/usage"

    private let rateLimits = """
        {"resources":{"core":{"used":10,"limit":5000,"reset":1800003600}}}
        """

    private let billing = """
        {"usageItems":[
          {"product":"Actions","sku":"actions_linux","quantity":1200,"unitType":"minutes",
           "grossAmount":9.6,"discountAmount":9.6,"netAmount":0.0},
          {"product":"Actions","sku":"actions_macos","quantity":300,"unitType":"minutes",
           "grossAmount":24.0,"discountAmount":0.0,"netAmount":24.0},
          {"product":"Packages","sku":"storage","quantity":50,"unitType":"GigabyteHours",
           "grossAmount":12.5,"discountAmount":0.0,"netAmount":12.5}
        ]}
        """

    // MARK: - Credential shapes

    func testBareTokenFetchesRateLimitsOnly() async throws {
        // No account means no billing endpoint to call — and asking anyway would 404.
        let http = FixtureHTTPClient(json: [rateLimitURL: rateLimits])
        let reading = try await GitHubProvider(http: http).fetch(secret: "ghp_x", now: now)

        XCTAssertEqual(http.recordedRequests.all.count, 1)
        XCTAssertNil(reading.account)
        XCTAssertNil(reading.metrics.first { $0.key == "spend" })
        XCTAssertNotNil(reading.metrics.first { $0.key == "rate_core" })
    }

    func testAccountPrefixedCredentialAlsoFetchesBilling() async throws {
        let http = FixtureHTTPClient(
            json: [rateLimitURL: rateLimits, userBillingURL: billing])
        let reading = try await GitHubProvider(http: http)
            .fetch(secret: "jmyers:ghp_x", now: now)

        XCTAssertEqual(reading.account, "jmyers")
        XCTAssertNotNil(reading.metrics.first { $0.key == "rate_core" })
        XCTAssertNotNil(reading.metrics.first { $0.key == "spend" })
    }

    func testAtPrefixSelectsTheOrganisationEndpoint() async throws {
        // Billing sits on the org for most teams. `@` cannot occur in a GitHub login, so
        // it is an unambiguous marker.
        let http = FixtureHTTPClient(
            json: [rateLimitURL: rateLimits, orgBillingURL: billing])
        _ = try await GitHubProvider(http: http).fetch(secret: "@acme:ghp_x", now: now)

        XCTAssertTrue(
            http.recordedRequests.all.contains { $0.url.absoluteString == orgBillingURL })
    }

    func testTokenContainingColonsSurvivesTheSplit() async throws {
        let http = FixtureHTTPClient(
            json: [rateLimitURL: rateLimits, userBillingURL: billing])
        _ = try await GitHubProvider(http: http).fetch(secret: "jmyers:gh:p:x", now: now)

        let auth = http.recordedRequests.all.first?.headers["Authorization"]
        XCTAssertEqual(auth, "Bearer gh:p:x")
    }

    // MARK: - Billing is best effort

    func testBillingFailureDoesNotDiscardRateLimits() async throws {
        // A token without `Plan: read` still answers /rate_limit perfectly well. Failing
        // the whole provider over the optional half would throw away a working answer to
        // punish a missing permission.
        let http = FixtureHTTPClient(json: [rateLimitURL: rateLimits])  // billing unrecorded
        let reading = try await GitHubProvider(http: http)
            .fetch(secret: "jmyers:ghp_x", now: now)

        XCTAssertNotNil(reading.metrics.first { $0.key == "rate_core" })
        XCTAssertNil(reading.metrics.first { $0.key == "spend" })
    }

    func testRateLimitFailureStillFailsTheProvider() async {
        // The mandatory half is not best effort: if it cannot be read there is nothing
        // worth reporting, and a partial answer would look like a healthy one.
        let http = FixtureHTTPClient(json: [userBillingURL: billing])
        do {
            _ = try await GitHubProvider(http: http).fetch(secret: "jmyers:ghp_x", now: now)
            XCTFail("expected a failure")
        } catch {}
    }

    // MARK: - Billing arithmetic

    func testSpendUsesNetAmountNotGross() async throws {
        // 0.0 + 24.0 + 12.5 — the fully discounted Actions line contributes nothing.
        // Reporting gross would overstate every bill that includes free minutes.
        let http = FixtureHTTPClient(
            json: [rateLimitURL: rateLimits, userBillingURL: billing])
        let reading = try await GitHubProvider(http: http)
            .fetch(secret: "jmyers:ghp_x", now: now)

        XCTAssertEqual(
            reading.metrics.first { $0.key == "spend" }?.value ?? 0, 36.5, accuracy: 0.001)
    }

    func testQuantitiesAggregateByProductAndUnit() async throws {
        // Two SKUs, one product, same unit — one figure. Minutes and gigabyte-hours stay
        // apart because they are not addable.
        let http = FixtureHTTPClient(
            json: [rateLimitURL: rateLimits, userBillingURL: billing])
        let reading = try await GitHubProvider(http: http)
            .fetch(secret: "jmyers:ghp_x", now: now)

        XCTAssertEqual(reading.metrics.first { $0.key == "Actions.minutes" }?.value, 1500)
        XCTAssertEqual(
            reading.metrics.first { $0.key == "Packages.GigabyteHours" }?.value, 50)
    }
}
