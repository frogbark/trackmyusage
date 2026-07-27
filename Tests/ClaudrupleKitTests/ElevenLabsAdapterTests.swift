import XCTest
@testable import ClaudrupleKit

/// ElevenLabs adapter.
///
/// The fixture mirrors `GET /v1/user/subscription` as documented: character_count,
/// character_limit, next_character_count_reset_unix, tier, status, voice_slots_used,
/// voice_limit. Parsing is a pure function of bytes, so this runs with no network and no
/// account — which is the point of splitting request-building from parsing.
final class ElevenLabsAdapterTests: XCTestCase {

    private let adapter = ElevenLabsAdapter()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let fixture = Data("""
        {
          "tier": "creator",
          "status": "active",
          "character_count": 45000,
          "character_limit": 100000,
          "next_character_count_reset_unix": 1800086400,
          "voice_slots_used": 3,
          "voice_limit": 30,
          "currency": "usd",
          "billing_period": "monthly_period",
          "can_extend_character_limit": true
        }
        """.utf8)

    // MARK: - Request

    func testRequestTargetsTheSubscriptionEndpoint() throws {
        let r = try adapter.request(credential: "sk-test")
        XCTAssertEqual(r.url?.absoluteString, "https://api.elevenlabs.io/v1/user/subscription")
    }

    func testCredentialGoesInTheApiKeyHeaderNotAQueryString() throws {
        // A key in a URL leaks into logs, proxies and shell history.
        let r = try adapter.request(credential: "sk-test")
        XCTAssertEqual(r.value(forHTTPHeaderField: "xi-api-key"), "sk-test")
        XCTAssertFalse(r.url?.absoluteString.contains("sk-test") ?? true)
    }

    // MARK: - Parsing

    func testParsesCharacterQuota() throws {
        let snap = try adapter.parse(fixture, now: now)
        let chars = try XCTUnwrap(snap.metrics.first { $0.key == "characters" })

        XCTAssertEqual(chars.value, 45000)
        XCTAssertEqual(chars.limit, 100000)
        XCTAssertEqual(chars.utilization, 45)
        XCTAssertEqual(chars.kind, .count)
    }

    func testCharacterResetDateIsCarried() throws {
        let snap = try adapter.parse(fixture, now: now)
        let chars = try XCTUnwrap(snap.metrics.first { $0.key == "characters" })
        XCTAssertEqual(chars.resetsAt, Date(timeIntervalSince1970: 1800086400))
    }

    func testParsesVoiceSlots() throws {
        let snap = try adapter.parse(fixture, now: now)
        let slots = try XCTUnwrap(snap.metrics.first { $0.key == "voice_slots" })
        XCTAssertEqual(slots.value, 3)
        XCTAssertEqual(slots.limit, 30)
    }

    func testAccountLabelUsesTheTier() throws {
        XCTAssertEqual(try adapter.parse(fixture, now: now).accountLabel, "creator")
    }

    func testBindingIsTheMostConstrainedQuota() throws {
        // characters 45% vs voice slots 10% — characters binds.
        XCTAssertEqual(try adapter.parse(fixture, now: now).binding?.key, "characters")
    }

    // MARK: - Degrading honestly

    func testMissingOptionalFieldsAreOmittedRatherThanZeroed() throws {
        // A free tier reports no voice limit. Emitting "0 of 0" would render as a full bar.
        let minimal = Data(#"{"tier":"free","character_count":10,"character_limit":100}"#.utf8)
        let snap = try adapter.parse(minimal, now: now)

        XCTAssertNotNil(snap.metrics.first { $0.key == "characters" })
        XCTAssertNil(snap.metrics.first { $0.key == "voice_slots" })
    }

    func testAResponseWithoutQuotaFieldsIsAnError() throws {
        // An authentication failure or an API change returns valid JSON with none of the
        // fields we need. Reporting that as "0% used" would be worse than failing.
        XCTAssertThrowsError(try adapter.parse(Data(#"{"detail":"unauthorized"}"#.utf8), now: now))
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try adapter.parse(Data("not json".utf8), now: now))
    }

    // MARK: - Spec

    func testCredentialSpecNamesTheLeastPrivilegedOption() {
        let spec = ElevenLabsAdapter.credentialSpec
        XCTAssertFalse(spec.createURL.isEmpty)
        XCTAssertFalse(spec.minimumScope.isEmpty)
    }
}
