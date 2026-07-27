import XCTest
@testable import ClaudrupleUsage

/// Stripe adapter.
///
/// `GET /v1/balance`, Basic auth with the secret key as the username and an empty password.
/// Amounts arrive in **minor units** — 666670 is $6,666.70 — which is the single detail
/// most likely to produce a number that is wrong by a factor of a hundred and still looks
/// plausible.
///
/// Stripe measures money coming *in*. Every other provider measures money going *out*, so
/// this must never be folded into a spend total.
final class StripeAdapterTests: XCTestCase {

    private let adapter = StripeAdapter()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let fixture = Data("""
        {
          "object": "balance",
          "livemode": true,
          "available": [{"amount": 666670, "currency": "usd", "source_types": {"card": 666670}}],
          "pending":   [{"amount":  61414, "currency": "usd", "source_types": {"card":  61414}}]
        }
        """.utf8)

    // MARK: - Request

    func testUsesBasicAuthWithTheKeyAsUsername() throws {
        let r = try adapter.request(credential: "sk_test_123")
        let header = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"))
        let decoded = String(
            data: Data(base64Encoded: String(header.dropFirst(6)))!, encoding: .utf8)

        // Stripe expects "key:" — the password half is empty.
        XCTAssertEqual(decoded, "sk_test_123:")
        XCTAssertFalse(r.url?.absoluteString.contains("sk_test") ?? true)
    }

    func testTargetsTheBalanceEndpoint() throws {
        XCTAssertEqual(
            try adapter.request(credential: "sk_test_123").url?.absoluteString,
            "https://api.stripe.com/v1/balance")
    }

    // MARK: - Parsing

    func testConvertsMinorUnitsToMajor() throws {
        let snap = try adapter.parse(fixture, now: now)
        let available = try XCTUnwrap(snap.metrics.first { $0.key == "available_usd" })

        XCTAssertEqual(available.value, 6666.70, accuracy: 0.001)
        XCTAssertEqual(available.unit, "USD")
        XCTAssertEqual(available.kind, .currency)
    }

    func testReportsPendingSeparatelyFromAvailable() throws {
        let snap = try adapter.parse(fixture, now: now)
        let pending = try XCTUnwrap(snap.metrics.first { $0.key == "pending_usd" })
        XCTAssertEqual(pending.value, 614.14, accuracy: 0.001)
    }

    func testHandlesMultipleCurrencies() throws {
        // Stripe returns one entry per currency; collapsing them would add euros to dollars.
        let multi = Data("""
            {"object":"balance","available":[
               {"amount":10000,"currency":"usd"},
               {"amount":25050,"currency":"eur"}],
             "pending":[]}
            """.utf8)

        let snap = try adapter.parse(multi, now: now)
        XCTAssertEqual(snap.metrics.first { $0.key == "available_usd" }?.value, 100)
        XCTAssertEqual(snap.metrics.first { $0.key == "available_eur" }?.value ?? 0, 250.5,
                       accuracy: 0.001)
    }

    func testNothingHasALimitSoStripeNeverBinds() throws {
        // A balance is not a quota. If it could bind, a healthy revenue figure would start
        // recommending that you switch accounts.
        let snap = try adapter.parse(fixture, now: now)
        XCTAssertNil(snap.binding)
        XCTAssertTrue(snap.metrics.allSatisfy { $0.limit == nil })
    }

    func testLivemodeIsSurfacedAsTheAccountLabel() throws {
        XCTAssertEqual(try adapter.parse(fixture, now: now).accountLabel, "live")

        let test = Data(#"{"object":"balance","livemode":false,"available":[{"amount":1,"currency":"usd"}],"pending":[]}"#.utf8)
        XCTAssertEqual(try adapter.parse(test, now: now).accountLabel, "test")
    }

    // MARK: - Degrading honestly

    func testAnErrorPayloadIsAnError() {
        // Stripe returns 200-shaped JSON with an `error` object on auth failure.
        XCTAssertThrowsError(
            try adapter.parse(Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8), now: now))
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try adapter.parse(Data("nope".utf8), now: now))
    }

    func testItConformsToTheAdapterContract() async {
        await ProviderConformance.assertConformance(
            StripeAdapter(), fixtures: .init(success: fixture))
    }
}
