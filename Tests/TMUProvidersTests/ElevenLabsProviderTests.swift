import XCTest

@testable import ClaudrupleUsage

/// ElevenLabs. Fixture mirrors `GET /v1/user/subscription` as documented.
final class ElevenLabsProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let body = """
        {"tier":"creator","status":"active",
         "character_count":45000,"character_limit":100000,
         "next_character_count_reset_unix":1800086400,
         "voice_slots_used":3,"voice_limit":30,"currency":"usd"}
        """

    private func provider(_ json: String) -> (ElevenLabsProvider, FixtureHTTPClient) {
        let http = FixtureHTTPClient(json: [ElevenLabsProvider.endpoint: json])
        return (ElevenLabsProvider(http: http), http)
    }

    func testKeyTravelsInTheHeaderNotTheURL() async throws {
        let (p, http) = provider(body)
        _ = try await p.fetch(secret: "sk-secret", now: now)

        let request = try XCTUnwrap(http.recordedRequests.all.first)
        XCTAssertEqual(request.headers["xi-api-key"], "sk-secret")
        XCTAssertFalse(request.url.absoluteString.contains("sk-secret"))
    }

    func testParsesCharacterQuotaAndResetDate() async throws {
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "k", now: now)
        let chars = try XCTUnwrap(reading.metrics.first { $0.key == "characters" })

        XCTAssertEqual(chars.value, 45000)
        XCTAssertEqual(chars.limit, 100000)
        XCTAssertEqual(chars.utilization, 45)
        XCTAssertEqual(chars.resetsAt, Date(timeIntervalSince1970: 1800086400))
        XCTAssertEqual(chars.unit, "chars")
    }

    func testTierBecomesTheAccountLabel() async throws {
        let (p, _) = provider(body)
        let reading = try await p.fetch(secret: "k", now: now)
        XCTAssertEqual(reading.account, "creator")
    }

    func testFreeTierWithoutVoiceLimitOmitsTheMetric() async throws {
        // Emitting "0 of 0" would render as a full bar.
        let (p, _) = provider(#"{"tier":"free","character_count":10,"character_limit":100}"#)
        let reading = try await p.fetch(secret: "k", now: now)

        XCTAssertNotNil(reading.metrics.first { $0.key == "characters" })
        XCTAssertNil(reading.metrics.first { $0.key == "voice_slots" })
    }

    func testResponseWithoutQuotaFieldsFails() async {
        // An auth failure returns valid JSON with none of the fields we need. Reporting
        // that as "0% used" would be worse than failing.
        let (p, _) = provider(#"{"detail":"unauthorized"}"#)
        do {
            _ = try await p.fetch(secret: "k", now: now)
            XCTFail("expected a failure")
        } catch {}
    }

    func testAFailureBecomesAnUnavailableSnapshotRatherThanThrowing() async {
        // One provider being down must not take out the render.
        let (p, _) = provider(#"{"detail":"unauthorized"}"#)
        let store = StubCredentials(stored: "k")

        let snapshot = await p.snapshot(credentials: store, now: now)

        XCTAssertFalse(snapshot.isReporting)
        XCTAssertEqual(snapshot.provider, "elevenlabs")
    }
}

/// A real conforming store, not a mock — tests need somewhere to put a secret.
struct StubCredentials: CredentialStore {
    var stored: String?
    func secret(for provider: String) throws -> String? { stored }
    func set(_ secret: String?, for provider: String) throws {}
}
