import Foundation

/// GitHub — API quota.
///
/// `GET /rate_limit`, verified against the REST documentation and a live call on
/// 2026-07-27. Unusually good to sample on a timer: the endpoint is documented as not
/// counting against the quota it reports, so watching it is free.
public struct GitHubAdapter: UsageProviderAdapter {

    public static let id = "github"
    public static let displayName = "GitHub"

    public static let credentialSpec = CredentialSpec(
        keychainService: "claudruple.github",
        createURL: "https://github.com/settings/personal-access-tokens",
        // As narrow as a credential gets: /rate_limit authenticates any token and grants
        // it nothing, so a token with every box unchecked works.
        minimumScope: "no scopes — a token with every permission left unchecked works",
        scopeWarning: nil)

    public static let capabilities = ProviderCapabilities(
        reportsSpend: false, reportsQuota: true)

    public init() {}

    /// The quotas worth watching, with the window each actually resets over.
    ///
    /// Search resets every minute and core every hour, so folding them into one number
    /// would misreport both — 9 of 30 search calls is a third of a minute's budget, not a
    /// third of an hour's.
    private static let resources:
        [(name: String, key: String, label: String, window: TimeInterval)] = [
            ("core", "rate_core", "Core API", 3600),
            ("search", "rate_search", "Search API", 60),
            ("graphql", "rate_graphql", "GraphQL API", 3600),
        ]

    public func request(credential: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!)
        // Header, never the URL — query strings reach proxy logs and crash reports.
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Pinned: unpinned, the request follows GitHub's current default, and a future
        // default could reshape the response under an adapter nobody is watching.
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    public func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resources = root["resources"] as? [String: Any]
        else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "no `resources` object")
        }

        // A resource GitHub did not return is skipped, not zeroed. Different token types
        // get different resource sets, and an unknown quota drawn as 0% reads as unlimited
        // headroom — the opposite of not knowing.
        let metrics = Self.resources.compactMap { resource -> ProviderMetric? in
            guard let entry = resources[resource.name] as? [String: Any],
                let used = entry["used"] as? Double,
                let limit = entry["limit"] as? Double, limit > 0
            else { return nil }

            return ProviderMetric(
                key: resource.key, label: resource.label, kind: .count,
                value: used, limit: limit, unit: "requests",
                window: .rolling(resource.window),
                resetsAt: (entry["reset"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }

        guard !metrics.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "no recognised rate limit resources")
        }

        return ProviderSnapshot(
            providerID: Self.id, accountLabel: nil, capturedAt: now, metrics: metrics)
    }
}
