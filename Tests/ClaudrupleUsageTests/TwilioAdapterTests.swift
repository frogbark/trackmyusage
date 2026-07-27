import XCTest
@testable import ClaudrupleUsage

/// Twilio adapter.
///
/// Fixture mirrors `GET /2010-04-01/Accounts/{Sid}/Usage/Records.json` as documented:
/// a `usage_records` array whose entries carry category, count, count_unit, usage,
/// usage_unit, price, price_unit and a start/end date. Note `count` and `usage` are
/// **strings** while `price` is a number — a detail worth pinning, since parsing price as
/// a string silently yields zero.
final class TwilioAdapterTests: XCTestCase {

    private let adapter = TwilioAdapter()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let fixture = Data("""
        {
          "usage_records": [
            {"category":"sms","description":"SMS","count":"1200","count_unit":"messages",
             "usage":"1200","usage_unit":"messages","price":9.6,"price_unit":"usd",
             "start_date":"2026-07-01","end_date":"2026-07-27"},
            {"category":"calls","description":"Voice","count":"48","count_unit":"calls",
             "usage":"312","usage_unit":"minutes","price":4.4,"price_unit":"usd",
             "start_date":"2026-07-01","end_date":"2026-07-27"}
          ]
        }
        """.utf8)

    // MARK: - Credential handling

    func testCredentialIsSplitIntoSidAndToken() throws {
        let r = try adapter.request(credential: "AC123:secrettoken")
        XCTAssertEqual(
            r.url?.absoluteString,
            "https://api.twilio.com/2010-04-01/Accounts/AC123/Usage/Records.json")
    }

    func testCredentialBecomesBasicAuthNotAQueryParameter() throws {
        let r = try adapter.request(credential: "AC123:secrettoken")
        let header = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"))

        XCTAssertTrue(header.hasPrefix("Basic "))
        let decoded = String(
            data: Data(base64Encoded: String(header.dropFirst(6)))!, encoding: .utf8)
        XCTAssertEqual(decoded, "AC123:secrettoken")
        XCTAssertFalse(r.url?.absoluteString.contains("secrettoken") ?? true)
    }

    func testCredentialWithoutASeparatorIsRejected() {
        // Twilio needs two values. Accepting a bare token would produce a request to
        // /Accounts//Usage and a confusing 404 rather than a clear setup error.
        XCTAssertThrowsError(try adapter.request(credential: "justatoken"))
    }

    func testAuthTokenContainingColonsIsPreserved() throws {
        // Split on the first separator only — a token is opaque and may contain colons.
        let r = try adapter.request(credential: "AC123:tok:en:with:colons")
        let header = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"))
        let decoded = String(
            data: Data(base64Encoded: String(header.dropFirst(6)))!, encoding: .utf8)
        XCTAssertEqual(decoded, "AC123:tok:en:with:colons")
    }

    // MARK: - Parsing

    func testSumsPriceAcrossCategories() throws {
        let snap = try adapter.parse(fixture, now: now)
        let spend = try XCTUnwrap(snap.metrics.first { $0.key == "spend" })

        XCTAssertEqual(spend.value, 14.0, accuracy: 0.001)
        XCTAssertEqual(spend.kind, .currency)
        XCTAssertEqual(spend.unit, "USD")
    }

    func testPrefersAnExplicitTotalpriceRecordOverSumming() throws {
        // Twilio reports a `totalprice` category alongside per-category rows. Summing
        // everything when that row is present would double-count.
        let withTotal = Data("""
            {"usage_records":[
              {"category":"sms","price":9.6,"price_unit":"usd","usage":"1200",
               "usage_unit":"messages","count":"1200","count_unit":"messages"},
              {"category":"totalprice","price":14.0,"price_unit":"usd","usage":"14",
               "usage_unit":"usd","count":"0","count_unit":"calls"}
            ]}
            """.utf8)

        let spend = try XCTUnwrap(
            try adapter.parse(withTotal, now: now).metrics.first { $0.key == "spend" })
        XCTAssertEqual(spend.value, 14.0, accuracy: 0.001)
    }

    func testSpendHasNoLimitSoItCannotBind() throws {
        // Pay-as-you-go: there is no cap, so no percentage exists and it must not be
        // treated as a constraint.
        let snap = try adapter.parse(fixture, now: now)
        let spend = try XCTUnwrap(snap.metrics.first { $0.key == "spend" })

        XCTAssertNil(spend.limit)
        XCTAssertNil(spend.utilization)
        XCTAssertNil(snap.binding)
    }

    func testPerCategoryUsageIsReported() throws {
        let snap = try adapter.parse(fixture, now: now)
        let sms = try XCTUnwrap(snap.metrics.first { $0.key == "sms" })

        // `usage` arrives as a string; reading it as a number would give zero.
        XCTAssertEqual(sms.value, 1200)
        XCTAssertEqual(sms.unit, "messages")
        XCTAssertEqual(sms.label, "SMS")
    }

    func testZeroPricedCategoriesAreOmitted() throws {
        // A Twilio account reports dozens of categories, nearly all at zero. Listing them
        // all would bury the two that matter.
        let noisy = Data("""
            {"usage_records":[
              {"category":"sms","description":"SMS","price":9.6,"price_unit":"usd",
               "usage":"1200","usage_unit":"messages","count":"1200","count_unit":"messages"},
              {"category":"fax","description":"Fax","price":0,"price_unit":"usd",
               "usage":"0","usage_unit":"pages","count":"0","count_unit":"faxes"}
            ]}
            """.utf8)

        let snap = try adapter.parse(noisy, now: now)
        XCTAssertNotNil(snap.metrics.first { $0.key == "sms" })
        XCTAssertNil(snap.metrics.first { $0.key == "fax" })
    }

    // MARK: - Degrading honestly

    func testEmptyRecordListIsAnError() {
        // An authenticated account always reports something. An empty array means the
        // request did not do what we think it did.
        XCTAssertThrowsError(try adapter.parse(Data(#"{"usage_records":[]}"#.utf8), now: now))
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try adapter.parse(Data("<html>403</html>".utf8), now: now))
    }

    func testItConformsToTheAdapterContract() async {
        await ProviderConformance.assertConformance(
            TwilioAdapter(), fixtures: .init(success: fixture, secret: "AC123:tok_conformance_secret"))
    }
}
