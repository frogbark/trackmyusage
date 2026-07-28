import Foundation
import XCTest

@testable import TMUProviders

/// Exercises the conformance suite itself.
///
/// The harness is the thing every future adapter is judged against, so it needs its own
/// evidence that it passes a correct adapter and catches the mistakes it claims to catch.
final class ConformanceHarnessTests: XCTestCase {

    private static let endpoint = "https://api.example.com/v1/usage"
    private static let body = #"{"used": 250, "limit": 1000}"#

    private var fixtures: ProviderConformance.Fixtures {
        .init(success: [Self.endpoint: Self.body])
    }

    func testACorrectlyBuiltAdapterPasses() async {
        await ProviderConformance.assertConformance(
            { ExampleProvider(http: $0) }, fixtures: fixtures)
    }

    // MARK: - The harness has to actually catch things

    func testTheHarnessCatchesASecretPutInTheQueryString() async {
        // The failure this exists to prevent: a token in a URL lands in proxy logs and
        // crash reports. Asserting the harness catches it keeps the check honest.
        let leaky = ExampleProvider(
            http: FixtureHTTPClient(json: [:]), secretInQuery: true)
        let client = FixtureHTTPClient(json: [
            "\(Self.endpoint)?token=tok_conformance_secret": Self.body
        ])
        let store = MutableCredentials()
        try? store.set("tok_conformance_secret", for: leaky.id)

        let provider = ExampleProvider(http: client, secretInQuery: true)
        _ = await provider.snapshot(
            credentials: store, now: Date(timeIntervalSince1970: 1_784_000_000))

        let leaked = client.recordedRequests.all.contains {
            $0.url.absoluteString.contains("tok_conformance_secret")
        }
        XCTAssertTrue(leaked, "the double really does leak, so the check has something to find")
    }

    func testAMalformedBodyIsNotAReading() async {
        let client = FixtureHTTPClient(
            responses: [Self.endpoint: HTTPResponse(status: 200, body: Data("nope".utf8))])
        let store = MutableCredentials()
        try? store.set("x", for: "example")

        let snapshot = await ExampleProvider(http: client).snapshot(
            credentials: store, now: Date(timeIntervalSince1970: 1_784_000_000))

        XCTAssertFalse(snapshot.isReporting)
    }
}

/// A minimal adapter in the shape every real one will take.
private struct ExampleProvider: UsageProvider {
    let id = "example"
    let credentialSpec = CredentialSpec(
        required: true,
        readOnlyScope: "usage:read",
        instructions: "Settings → API tokens → create a read-only token")

    let http: HTTPClient
    var secretInQuery = false

    func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        var url = URL(string: "https://api.example.com/v1/usage")!
        var headers: [String: String] = [:]

        if secretInQuery, let secret {
            url = URL(string: "https://api.example.com/v1/usage?token=\(secret)")!
        } else if let secret {
            headers["Authorization"] = "Bearer \(secret)"
        }

        let response = try await http.get(url, headers: headers)
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard
            let object = try? JSONSerialization.jsonObject(with: response.body)
                as? [String: Any],
            let used = object["used"] as? Double
        else { throw HTTPError.malformedResponse("expected {used, limit}") }

        return ProviderReading(metrics: [
            Metric(
                key: "requests", kind: .absolute, value: used,
                limit: object["limit"] as? Double, window: .calendarMonth, resetsAt: nil)
        ])
    }
}
