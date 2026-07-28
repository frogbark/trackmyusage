import Foundation
import XCTest

@testable import TMUProviders

/// The contract every adapter has to satisfy, run against recorded fixtures.
///
/// This is what makes seventeen integrations maintainable by people who do not hold
/// seventeen paid accounts. A contributor adds or changes an adapter, runs this, and knows
/// whether they broke it — without a credential, without spending money, without waiting
/// out a rate limit.
///
/// Adapter tests call `assertConformance` and then add whatever is specific to their
/// provider on top.
enum ProviderConformance {

    struct Fixtures {
        /// A recorded successful response, keyed by absolute URL.
        let success: [String: String]
        /// A credential that looks real enough to be searched for in the request.
        let secret: String

        init(success: [String: String], secret: String = "tok_conformance_secret") {
            self.success = success
            self.secret = secret
        }
    }

    static func assertConformance<P: UsageProvider>(
        _ make: (HTTPClient) -> P,
        fixtures: Fixtures,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let store = MutableCredentials()
        try? store.set(fixtures.secret, for: make(FixtureHTTPClient(json: [:])).id)

        // 1 — the happy path produces readings.
        let ok = FixtureHTTPClient(json: fixtures.success)
        let good = await make(ok).snapshot(credentials: store, now: now)
        XCTAssertTrue(
            good.isReporting, "a recorded success must produce a reading", file: file,
            line: line)
        XCTAssertFalse(
            good.metrics.isEmpty, "a reporting snapshot with no metrics says nothing",
            file: file, line: line)
        for metric in good.metrics {
            XCTAssertFalse(
                metric.key.isEmpty, "every metric needs a key to be stored under",
                file: file, line: line)
            XCTAssertTrue(
                metric.value.isFinite, "a non-finite value poisons every chart downstream",
                file: file, line: line)
        }

        // 2 — the secret travels in a header, never in the URL.
        //
        // A token in a query string ends up in proxy logs, browser history, and crash
        // reports. This is the one conformance check that is about safety rather than
        // correctness, which is why it is enforced rather than documented.
        for request in ok.recordedRequests.all {
            XCTAssertFalse(
                request.url.absoluteString.contains(fixtures.secret),
                "the credential must not appear in \(request.url)", file: file, line: line)
        }

        // 3 — a server error degrades rather than propagates.
        let failing = FixtureHTTPClient(
            responses: fixtures.success.mapValues { _ in
                HTTPResponse(status: 500, body: Data("upstream exploded".utf8))
            })
        let broken = await make(failing).snapshot(credentials: store, now: now)
        XCTAssertFalse(
            broken.isReporting, "a 500 is not a reading", file: file, line: line)
        XCTAssertEqual(
            broken.provider, good.provider,
            "a failed provider keeps its identity so it still occupies its row", file: file,
            line: line)

        // 4 — a malformed body degrades rather than crashes. Providers change their
        // response shapes without warning, and that must cost one blank row.
        let garbage = FixtureHTTPClient(
            responses: fixtures.success.mapValues { _ in
                HTTPResponse(status: 200, body: Data("<html>not json</html>".utf8))
            })
        let mangled = await make(garbage).snapshot(credentials: store, now: now)
        XCTAssertFalse(
            mangled.isReporting, "an unparseable body is not a reading", file: file,
            line: line)

        // 5 — without a credential it reports unauthorized and makes no call at all.
        let untouched = FixtureHTTPClient(json: fixtures.success)
        let provider = make(untouched)
        if provider.credentialSpec.required {
            let empty = await provider.snapshot(credentials: MutableCredentials(), now: now)
            XCTAssertEqual(
                empty.status, .unauthorized,
                "an unconnected provider is unauthorized, not unavailable", file: file,
                line: line)
            XCTAssertTrue(
                untouched.recordedRequests.all.isEmpty,
                "no request should be made without a credential", file: file, line: line)
        }

        // 6 — the declared scope is real, and says where to get one.
        XCTAssertFalse(
            provider.credentialSpec.readOnlyScope.isEmpty,
            "the minimum scope travels with the adapter", file: file, line: line)
        XCTAssertFalse(
            provider.credentialSpec.instructions.isEmpty,
            "the UI has to tell someone where to click", file: file, line: line)
    }
}

final class MutableCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func secret(for provider: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[provider]
    }

    func set(_ secret: String?, for provider: String) throws {
        lock.lock()
        secrets[provider] = secret
        lock.unlock()
    }
}
