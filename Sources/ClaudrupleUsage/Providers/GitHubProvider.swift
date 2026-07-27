import Foundation

/// GitHub API quota.
///
/// Verified against the REST documentation and a live call to the endpoint on 2026-07-27.
/// `GET /rate_limit` is the rare usage endpoint that is both unauthenticated-readable and
/// documented as not counting against the quota it reports, so sampling it costs nothing.
///
/// Roadmap tier 2.
public struct GitHubProvider: UsageProvider {

    public static let endpoint = "https://api.github.com/rate_limit"

    public let id = "github"

    /// `/rate_limit` needs no scopes at all — any token authenticates, and none of them
    /// grant it anything. That is as narrow as a credential gets.
    public let credentialSpec = CredentialSpec(
        required: true,
        readOnlyScope: "no scopes required — a token with every box unchecked works",
        instructions:
            "GitHub → Settings → Developer settings → Personal access tokens → "
            + "generate a token and grant it nothing")

    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The quotas worth watching, with the window each one actually resets over.
    ///
    /// Search resets every minute and core every hour, so folding them into one number
    /// would misreport both — 9 of 30 search calls is a third of a minute's budget, not a
    /// third of an hour's.
    private static let resources: [(name: String, key: String, window: TimeInterval)] = [
        ("core", "rate_core", 3600),
        ("search", "rate_search", 60),
        ("graphql", "rate_graphql", 3600),
    ]

    public func fetch(secret: String?, now: Date) async throws -> [Metric] {
        guard let url = URL(string: Self.endpoint) else {
            throw HTTPError.malformedResponse("bad endpoint")
        }

        var headers = [
            "Accept": "application/vnd.github+json",
            // Pinned: an unpinned request follows GitHub's current default, and a future
            // default could reshape the response under an adapter nobody is watching.
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if let secret { headers["Authorization"] = "Bearer \(secret)" }

        let response = try await http.get(url, headers: headers)
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard
            let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let resources = root["resources"] as? [String: Any]
        else { throw HTTPError.malformedResponse("expected a `resources` object") }

        // A resource GitHub did not return is skipped, not zeroed. Different token types
        // get different resource sets, and an absent quota drawn as 0% reads as unlimited
        // headroom — the opposite of not knowing.
        return Self.resources.compactMap { resource in
            guard let entry = resources[resource.name] as? [String: Any],
                let used = entry["used"] as? Double,
                let limit = entry["limit"] as? Double
            else { return nil }

            return Metric(
                key: resource.key, kind: .absolute, value: used, limit: limit,
                window: .rolling(resource.window),
                resetsAt: (entry["reset"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
    }
}
