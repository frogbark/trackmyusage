import XCTest
@testable import ClaudrupleKit

/// GitHub adapter.
///
/// `GET /users/{username}/settings/billing/usage` (or the `/organizations/{org}/…`
/// variant), returning `{usageItems: [{date, product, sku, quantity, unitType,
/// pricePerUnit, grossAmount, discountAmount, netAmount, …}]}`.
///
/// `netAmount` is what is actually charged after plan allowances; `grossAmount` is the
/// list price. Reporting gross would overstate every bill that includes free minutes.
final class GitHubAdapterTests: XCTestCase {

    private let adapter = GitHubAdapter()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let fixture = Data("""
        {"usageItems":[
          {"date":"2026-07-01","product":"Actions","sku":"actions_linux","quantity":1200,
           "unitType":"minutes","pricePerUnit":0.008,"grossAmount":9.6,
           "discountAmount":9.6,"netAmount":0.0},
          {"date":"2026-07-02","product":"Actions","sku":"actions_macos","quantity":300,
           "unitType":"minutes","pricePerUnit":0.08,"grossAmount":24.0,
           "discountAmount":0.0,"netAmount":24.0},
          {"date":"2026-07-03","product":"Packages","sku":"packages_storage","quantity":50,
           "unitType":"GigabyteHours","pricePerUnit":0.25,"grossAmount":12.5,
           "discountAmount":0.0,"netAmount":12.5}
        ]}
        """.utf8)

    // MARK: - Account selection

    func testUsernameCredentialTargetsTheUserEndpoint() throws {
        let r = try adapter.request(credential: "jmyers:ghp_token")
        XCTAssertEqual(
            r.url?.absoluteString,
            "https://api.github.com/users/jmyers/settings/billing/usage")
    }

    func testAtPrefixSelectsTheOrganisationEndpoint() throws {
        // Billing sits on the org for most teams, so both have to be reachable. A leading
        // @ is the smallest unambiguous marker — it cannot occur in a GitHub login.
        let r = try adapter.request(credential: "@acme:ghp_token")
        XCTAssertEqual(
            r.url?.absoluteString,
            "https://api.github.com/organizations/acme/settings/billing/usage")
    }

    func testTokenTravelsAsABearerHeader() throws {
        let r = try adapter.request(credential: "jmyers:ghp_token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_token")
        XCTAssertFalse(r.url?.absoluteString.contains("ghp_token") ?? true)
    }

    func testApiVersionHeaderIsPinned() throws {
        // GitHub versions its REST API by header; omitting it opts into whatever becomes
        // current, which is how a working adapter breaks without a code change.
        let r = try adapter.request(credential: "jmyers:ghp_token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testCredentialWithoutASeparatorIsRejected() {
        XCTAssertThrowsError(try adapter.request(credential: "ghp_tokenonly"))
    }

    // MARK: - Parsing

    func testSpendUsesNetAmountNotGross() throws {
        // 0.0 + 24.0 + 12.5 — the discounted Actions line contributes nothing.
        let snap = try adapter.parse(fixture, now: now)
        let spend = try XCTUnwrap(snap.metrics.first { $0.key == "spend" })

        XCTAssertEqual(spend.value, 36.5, accuracy: 0.001)
        XCTAssertEqual(spend.kind, .currency)
        XCTAssertNil(spend.limit, "GitHub billing is uncapped, so it cannot bind")
    }

    func testQuantitiesAreAggregatedPerProductAndUnit() throws {
        // Two Actions rows with different SKUs but the same unit collapse into one figure.
        let snap = try adapter.parse(fixture, now: now)
        let actions = try XCTUnwrap(snap.metrics.first { $0.key == "Actions.minutes" })

        XCTAssertEqual(actions.value, 1500)
        XCTAssertEqual(actions.unit, "minutes")
    }

    func testProductsWithDifferentUnitsStaySeparate() throws {
        // Minutes and gigabyte-hours are not addable.
        let snap = try adapter.parse(fixture, now: now)
        XCTAssertEqual(
            snap.metrics.first { $0.key == "Packages.GigabyteHours" }?.value, 50)
    }

    func testEmptyUsageIsNotAnError() throws {
        // A new account genuinely has no billable usage yet — unlike Twilio, zero rows is
        // a legitimate state rather than a sign the request went wrong.
        let snap = try adapter.parse(Data(#"{"usageItems":[]}"#.utf8), now: now)
        XCTAssertEqual(snap.metrics.first { $0.key == "spend" }?.value, 0)
    }

    // MARK: - Degrading honestly

    func testMissingUsageItemsIsAnError() {
        XCTAssertThrowsError(try adapter.parse(Data(#"{"message":"Not Found"}"#.utf8), now: now))
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try adapter.parse(Data("<html>".utf8), now: now))
    }
}
