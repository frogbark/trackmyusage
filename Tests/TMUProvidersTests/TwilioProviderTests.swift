import XCTest

@testable import TMUProviders

/// Twilio. `count` and `usage` arrive as strings while `price` is a number — the detail
/// that would otherwise report zero usage against a real bill.
final class TwilioProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = "https://api.twilio.com/2010-04-01/Accounts/AC123/Usage/Records.json"

    private let body = """
        {"usage_records":[
          {"category":"sms","description":"SMS","count":"1200","count_unit":"messages",
           "usage":"1200","usage_unit":"messages","price":9.6,"price_unit":"usd"},
          {"category":"calls","description":"Voice","count":"48","count_unit":"calls",
           "usage":"312","usage_unit":"minutes","price":4.4,"price_unit":"usd"}
        ]}
        """

    private func provider(_ json: String) -> (TwilioProvider, FixtureHTTPClient) {
        let http = FixtureHTTPClient(json: [url: json])
        return (TwilioProvider(http: http), http)
    }

    func testSidSelectsTheAccountAndTheTokenGoesInBasicAuth() async throws {
        let (p, http) = provider(body)
        _ = try await p.fetch(secret: "AC123:secrettoken", now: now)

        let request = try XCTUnwrap(http.recordedRequests.all.first)
        XCTAssertEqual(request.url.absoluteString, url)

        let header = try XCTUnwrap(request.headers["Authorization"])
        let decoded = String(
            data: Data(base64Encoded: String(header.dropFirst(6)))!, encoding: .utf8)
        XCTAssertEqual(decoded, "AC123:secrettoken")
        XCTAssertFalse(request.url.absoluteString.contains("secrettoken"))
    }

    func testCredentialWithoutASeparatorFails() async {
        // Twilio needs two values; a bare token would request /Accounts//Usage and 404.
        let (p, _) = provider(body)
        do {
            _ = try await p.fetch(secret: "justatoken", now: now)
            XCTFail("expected a failure")
        } catch {}
    }

    func testSumsPriceAndParsesStringUsage() async throws {
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "AC123:t", now: now)

        XCTAssertEqual(
            reading.metrics.first { $0.key == "spend" }?.value ?? 0, 14.0, accuracy: 0.001)
        XCTAssertEqual(reading.metrics.first { $0.key == "sms" }?.value, 1200)
    }

    func testSpendCarriesNoLimitSoItCannotBind() async throws {
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "AC123:t", now: now)
        let spend = try XCTUnwrap(reading.metrics.first { $0.key == "spend" })

        XCTAssertNil(spend.limit)
        XCTAssertNil(spend.utilization)
    }

    func testPrefersTotalpriceOverSumming() async throws {
        // Summing when the totalprice row is present double-counts.
        let (p, _) = provider(
            """
            {"usage_records":[
              {"category":"sms","price":9.6,"price_unit":"usd","usage":"1200"},
              {"category":"totalprice","price":14.0,"price_unit":"usd","usage":"14"}
            ]}
            """)
        let reading = try await p.fetch(secret: "AC123:t", now: now)
        XCTAssertEqual(
            reading.metrics.first { $0.key == "spend" }?.value ?? 0, 14.0, accuracy: 0.001)
    }

    func testZeroPricedCategoriesAreOmitted() async throws {
        // An account reports dozens of categories, nearly all zero; they bury the rest.
        let (p, _) = provider(
            """
            {"usage_records":[
              {"category":"sms","price":9.6,"price_unit":"usd","usage":"1200"},
              {"category":"fax","price":0,"price_unit":"usd","usage":"0"}
            ]}
            """)
        let reading = try await p.fetch(secret: "AC123:t", now: now)

        XCTAssertNotNil(reading.metrics.first { $0.key == "sms" })
        XCTAssertNil(reading.metrics.first { $0.key == "fax" })
    }
}
