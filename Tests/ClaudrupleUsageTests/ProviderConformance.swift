import Foundation
import XCTest

@testable import ClaudrupleUsage

/// The contract every adapter has to satisfy, run against a recorded response.
///
/// This is what makes seventeen integrations maintainable by people who do not hold
/// seventeen paid accounts. A contributor changes an adapter, runs `swift test`, and learns
/// whether they broke it — no credential, no spend, no waiting out a rate limit.
///
/// It leans on the adapter protocol being split: `parse` is a pure function of `Data`, so
/// most of this exercises the real parser directly rather than through a fake network.
enum ProviderConformance {

    struct Fixtures {
        /// A recorded successful response body.
        let success: Data
        /// A credential shaped like the real thing, so it can be searched for in the request.
        let secret: String

        init(success: String, secret: String = "tok_conformance_secret") {
            self.success = Data(success.utf8)
            self.secret = secret
        }

        init(success: Data, secret: String = "tok_conformance_secret") {
            self.success = success
            self.secret = secret
        }
    }

    static func assertConformance(
        _ adapter: any UsageProviderAdapter,
        fixtures: Fixtures,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let now = Date(timeIntervalSince1970: 1_784_000_000)

        // 1 — the recorded response parses into usable readings.
        let parsed: ProviderSnapshot
        do {
            parsed = try adapter.parse(fixtures.success, now: now)
        } catch {
            return XCTFail("the recorded response must parse: \(error)", file: file, line: line)
        }
        XCTAssertEqual(
            parsed.providerID, adapter.id,
            "a snapshot has to say which provider produced it", file: file, line: line)
        XCTAssertTrue(parsed.isReporting, file: file, line: line)
        XCTAssertFalse(
            parsed.metrics.isEmpty, "a reporting snapshot with no metrics says nothing",
            file: file, line: line)
        for metric in parsed.metrics {
            XCTAssertFalse(
                metric.key.isEmpty, "every metric needs a key to be stored under", file: file,
                line: line)
            XCTAssertFalse(
                metric.label.isEmpty, "and a label, since the UI shows it", file: file,
                line: line)
            XCTAssertTrue(
                metric.value.isFinite, "a non-finite value poisons every chart downstream",
                file: file, line: line)
            if let limit = metric.limit {
                XCTAssertGreaterThan(
                    limit, 0, "a zero limit divides to infinity and pins the gauge full",
                    file: file, line: line)
            }
        }

        // 2 — the credential travels in a header, never in the URL.
        //
        // A token in a query string ends up in proxy logs, browser history and crash
        // reports. The one conformance check that is about safety rather than correctness,
        // which is why it is enforced rather than documented.
        let request: URLRequest
        do {
            request = try adapter.request(credential: fixtures.secret)
        } catch {
            return XCTFail("building a request must succeed: \(error)", file: file, line: line)
        }
        let url = request.url?.absoluteString ?? ""
        XCTAssertFalse(
            url.contains(fixtures.secret), "the credential must not appear in \(url)",
            file: file, line: line)
        XCTAssertTrue(
            isCarried(fixtures.secret, in: request),
            "the credential has to be sent somewhere other than the URL", file: file,
            line: line)

        // 3 — garbage does not become a reading.
        XCTAssertThrowsError(
            try adapter.parse(Data("<html>not json</html>".utf8), now: now),
            "providers reshape responses without warning; that must cost one blank row",
            file: file, line: line)

        // 4 — the runner turns every failure into a status.
        var store = InMemoryCredentialStore()
        try? store.set(fixtures.secret, for: adapter.credentialSpec.keychainService)

        let broken = FixtureExecutor(
            responses: [url: HTTPResponse(status: 500, body: Data("upstream exploded".utf8))])
        let failed = await ProviderRunner(executor: broken)
            .snapshot(of: adapter, credentials: store, now: now)
        XCTAssertFalse(failed.isReporting, "a 500 is not a reading", file: file, line: line)
        XCTAssertEqual(
            failed.providerID, adapter.id,
            "a failed provider keeps its identity so it still occupies its row", file: file,
            line: line)

        let rejected = FixtureExecutor(
            responses: [url: HTTPResponse(status: 401, body: Data())])
        let unauthorized = await ProviderRunner(executor: rejected)
            .snapshot(of: adapter, credentials: store, now: now)
        XCTAssertEqual(
            unauthorized.status, .unauthorized,
            "a rejected token needs replacing, not waiting out — the two must not collapse",
            file: file, line: line)

        // 5 — without a credential it reports unauthorized and makes no call at all.
        let untouched = FixtureExecutor(
            responses: [url: HTTPResponse(status: 200, body: fixtures.success)])
        let empty = await ProviderRunner(executor: untouched)
            .snapshot(of: adapter, credentials: InMemoryCredentialStore(), now: now)
        XCTAssertEqual(
            empty.status, .unauthorized,
            "an unconnected provider is unauthorized, not unavailable", file: file, line: line)
        XCTAssertTrue(
            untouched.recorded.all.isEmpty,
            "an unconnected provider should cost no request and no rate-limit budget",
            file: file, line: line)

        // 6 — the happy path survives the whole runner, not just the parser.
        let good = FixtureExecutor(
            responses: [url: HTTPResponse(status: 200, body: fixtures.success)])
        let live = await ProviderRunner(executor: good)
            .snapshot(of: adapter, credentials: store, now: now)
        XCTAssertTrue(live.isReporting, file: file, line: line)

        // 7 — the declared credential says where to get one and how narrow it can be.
        XCTAssertFalse(
            adapter.credentialSpec.keychainService.isEmpty, file: file, line: line)
        XCTAssertFalse(
            adapter.credentialSpec.minimumScope.isEmpty,
            "the minimum scope travels with the adapter", file: file, line: line)
        XCTAssertFalse(
            adapter.credentialSpec.createURL.isEmpty,
            "the UI has to tell someone where to click", file: file, line: line)
    }

    /// Whether the credential is actually being sent, wherever an adapter chose to put it.
    ///
    /// Basic auth base64-encodes "user:password", and adapters assemble that differently —
    /// Stripe appends a colon for an empty password, Twilio uses the credential verbatim.
    /// Decoding the header rather than guessing at the encoding is what stops this check
    /// from failing a perfectly correct adapter.
    private static func isCarried(_ secret: String, in request: URLRequest) -> Bool {
        let headers = request.allHTTPHeaderFields ?? [:]
        if headers.values.contains(where: { $0.contains(secret) }) { return true }

        for value in headers.values where value.hasPrefix("Basic ") {
            guard let data = Data(base64Encoded: String(value.dropFirst(6))),
                let decoded = String(data: data, encoding: .utf8)
            else { continue }
            if decoded.contains(secret) { return true }
        }

        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8)
        else { return false }
        return text.contains(secret)
    }
}
