import XCTest
@testable import ClaudrupleUsage

/// How a rejected credential is reported.
///
/// A missing token and a rejected one call for the same action — replace it — and both are
/// different from a provider being briefly down. Collapsing a 401 into "unavailable" tells
/// someone to wait out a token that will never start working.
final class AuthFailureTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct RejectingProvider: UsageProvider {
        let id = "demo"
        let status: Int
        var credentialSpec: CredentialSpec {
            CredentialSpec(required: true, readOnlyScope: "read", instructions: "…")
        }
        func fetch(secret: String?, now: Date) async throws -> ProviderReading {
            throw HTTPError.status(status)
        }
    }

    private struct Store: CredentialStore {
        var stored: String?
        func secret(for provider: String) throws -> String? { stored }
        func set(_ secret: String?, for provider: String) throws {}
    }

    func testRejectedTokenReportsUnauthorizedNotUnavailable() async {
        let snapshot = await RejectingProvider(status: 401)
            .snapshot(credentials: Store(stored: "stale-token"), now: now)

        XCTAssertEqual(
            snapshot.status, .unauthorized,
            "a 401 needs the token replaced, not waited out")
    }

    func testForbiddenAlsoReportsUnauthorized() async {
        // 403 is the shape of a token that is valid but lacks the scope. Same remedy:
        // issue a new one with the right permission.
        let snapshot = await RejectingProvider(status: 403)
            .snapshot(credentials: Store(stored: "wrong-scope"), now: now)

        XCTAssertEqual(snapshot.status, .unauthorized)
    }

    func testServerErrorsStayUnavailable() async {
        // A 500 or a 429 really is worth waiting out; telling someone to re-paste a
        // working token would send them to fix the wrong thing.
        for code in [429, 500, 503] {
            let snapshot = await RejectingProvider(status: code)
                .snapshot(credentials: Store(stored: "fine"), now: now)

            guard case .unavailable = snapshot.status else {
                return XCTFail("HTTP \(code) should be unavailable, got \(snapshot.status)")
            }
        }
    }

    func testMissingCredentialIsStillUnauthorized() async {
        let snapshot = await RejectingProvider(status: 500)
            .snapshot(credentials: Store(stored: nil), now: now)

        XCTAssertEqual(
            snapshot.status, .unauthorized,
            "never asked, because there was nothing to ask with")
    }
}
