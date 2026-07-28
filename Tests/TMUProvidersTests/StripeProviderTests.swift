import XCTest

@testable import TMUProviders

/// Stripe. Amounts arrive in minor units — 666670 is 6666.70 — which is the detail most
/// likely to produce a figure wrong by 100x that still looks plausible.
final class StripeProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let body = """
        {"object":"balance","livemode":true,
         "available":[{"amount":666670,"currency":"usd"}],
         "pending":[{"amount":61414,"currency":"usd"}]}
        """

    private func provider(_ json: String) -> (StripeProvider, FixtureHTTPClient) {
        let http = FixtureHTTPClient(json: [StripeProvider.endpoint: json])
        return (StripeProvider(http: http), http)
    }

    func testKeyGoesInTheUsernameHalfOfBasicAuth() async throws {
        let (p, http) = provider(body)
        _ = try await p.fetch(secret: "sk_test_123", now: now)

        let header = try XCTUnwrap(http.recordedRequests.all.first?.headers["Authorization"])
        let decoded = String(
            data: Data(base64Encoded: String(header.dropFirst(6)))!, encoding: .utf8)
        // Stripe expects "key:" — the password half is empty.
        XCTAssertEqual(decoded, "sk_test_123:")
    }

    func testConvertsMinorUnitsToMajor() async throws {
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "sk", now: now)

        XCTAssertEqual(
            reading.metrics.first { $0.key == "available_usd" }?.value ?? 0,
            6666.70, accuracy: 0.001)
        XCTAssertEqual(
            reading.metrics.first { $0.key == "pending_usd" }?.value ?? 0,
            614.14, accuracy: 0.001)
    }

    func testCurrenciesStaySeparate() async throws {
        // Collapsing them would add euros to dollars.
        let (p, _) = provider(
            """
            {"object":"balance","available":[
               {"amount":10000,"currency":"usd"},{"amount":25050,"currency":"eur"}],
             "pending":[]}
            """)
        let reading = try await p.fetch(secret: "sk", now: now)

        XCTAssertEqual(reading.metrics.first { $0.key == "available_usd" }?.value, 100)
        XCTAssertEqual(
            reading.metrics.first { $0.key == "available_eur" }?.value ?? 0, 250.5,
            accuracy: 0.001)
    }

    func testRevenueNeverBinds() async throws {
        // A balance is not a quota. If it could bind, a healthy revenue figure would start
        // recommending an account switch.
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "sk", now: now)
        let snapshot = UsageSnapshot(
            provider: "stripe", account: nil, observedAt: now,
            status: .ok, metrics: reading.metrics)

        XCTAssertNil(snapshot.binding)
        XCTAssertTrue(reading.metrics.allSatisfy { $0.limit == nil })
    }

    func testLivemodeBecomesTheAccountLabel() async throws {
        let (live, _) = provider(body)
        let liveReading = try await live.fetch(secret: "sk", now: now)
        XCTAssertEqual(liveReading.account, "live")

        let (test, _) = provider(
            #"{"object":"balance","livemode":false,"available":[{"amount":1,"currency":"usd"}],"pending":[]}"#
        )
        let testReading = try await test.fetch(secret: "sk", now: now)
        XCTAssertEqual(testReading.account, "test")
    }

    func testErrorPayloadFails() async {
        // Stripe reports auth failures as a well-formed body carrying an `error` object.
        let (p, _) = provider(#"{"error":{"message":"Invalid API Key"}}"#)
        do {
            _ = try await p.fetch(secret: "bad", now: now)
            XCTFail("expected a failure")
        } catch {}
    }
}
