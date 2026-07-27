import Foundation

/// GitHub — API rate limits and, when the credential names an account, billed usage.
///
/// Two endpoints behind one provider because one token answers both and nobody wants to
/// paste the same PAT twice. They measure different things: `/rate_limit` is a quota that
/// stops work now, billing is money already spent.
///
/// Billing is best-effort. A token without `Plan: read` still answers `/rate_limit`
/// perfectly well, and failing the whole provider over the optional half would throw away
/// a working answer to punish a missing permission.
public struct GitHubProvider: UsageProvider {

    public static let rateLimitEndpoint = "https://api.github.com/rate_limit"

    public let id = "github"
    public let credentialSpec = CredentialSpec(
        // Not required: /rate_limit answers unauthenticated, at a much lower ceiling.
        required: false,
        readOnlyScope: "fine-grained PAT — \"Plan: read\" for billing; none for rate limits",
        instructions:
            "Store as \"username:token\", or \"@org:token\" for organisation billing. "
            + "A bare token reports rate limits only.",
        createURL: "https://github.com/settings/personal-access-tokens",
        scopeWarning:
            "A classic token with repo scope can read and write your code. Use a "
            + "fine-grained token limited to billing.")

    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The quotas worth watching, with the window each one actually resets over.
    ///
    /// Search resets every minute and core every hour, so folding them into one number
    /// would misreport both — 9 of 30 search calls is a third of a minute's budget, not a
    /// third of an hour's.
    private static let resources: [(name: String, key: String, label: String, window: TimeInterval)] = [
        ("core", "rate_core", "API (core)", 3600),
        ("search", "rate_search", "API (search)", 60),
        ("graphql", "rate_graphql", "API (GraphQL)", 3600),
    ]

    public func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        let (account, token) = Self.split(secret)

        var metrics = try await rateLimits(token: token)
        if let account {
            // Best effort: a billing failure must not discard the rate-limit readings.
            metrics += (try? await billing(account: account, token: token)) ?? []
        }
        return ProviderReading(account: account, metrics: metrics)
    }

    // MARK: - Credential

    /// Split `"account:token"` on the first separator only — a token is opaque and may
    /// itself contain colons. A bare token yields no account, which disables billing.
    static func split(_ secret: String?) -> (account: String?, token: String?) {
        guard let secret, !secret.isEmpty else { return (nil, nil) }
        guard let sep = secret.firstIndex(of: ":") else { return (nil, secret) }

        let account = String(secret[secret.startIndex..<sep])
        let token = String(secret[secret.index(after: sep)...])
        return (account.isEmpty ? nil : account, token.isEmpty ? nil : token)
    }

    private func headers(_ token: String?) -> [String: String] {
        var h = [
            "Accept": "application/vnd.github+json",
            // Pinned: an unpinned request follows GitHub's current default, and a future
            // default could reshape the response under an adapter nobody is watching.
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    // MARK: - Rate limits

    private func rateLimits(token: String?) async throws -> [Metric] {
        guard let url = URL(string: Self.rateLimitEndpoint) else {
            throw HTTPError.malformedResponse("bad endpoint")
        }
        let response = try await http.get(url, headers: headers(token))
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
                resetsAt: (entry["reset"] as? Double).map(Date.init(timeIntervalSince1970:)),
                label: resource.label, unit: "requests")
        }
    }

    // MARK: - Billing

    /// `GET /users/{login}/settings/billing/usage`, or the organisation variant when the
    /// account is written `@org`. Billing sits on the org for most teams, and `@` cannot
    /// occur in a GitHub login so it is unambiguous.
    private func billing(account: String, token: String?) async throws -> [Metric] {
        var name = account
        let isOrg = name.hasPrefix("@")
        if isOrg { name.removeFirst() }

        let path = isOrg
            ? "organizations/\(name)/settings/billing/usage"
            : "users/\(name)/settings/billing/usage"
        guard let url = URL(string: "https://api.github.com/\(path)") else { return [] }

        let response = try await http.get(url, headers: headers(token))
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard
            let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let items = root["usageItems"] as? [[String: Any]]
        else { throw HTTPError.malformedResponse("expected a `usageItems` array") }

        // netAmount is what is actually charged after plan allowances; grossAmount is list
        // price. Reporting gross overstates every bill that includes free minutes.
        let spend = items.reduce(0.0) { $0 + (($1["netAmount"] as? Double) ?? 0) }
        var metrics = [
            Metric(
                key: "spend", kind: .currency, value: spend, limit: nil,
                window: .billingPeriod, resetsAt: nil, label: "Spend", unit: "USD")
        ]

        // Aggregate by product *and* unit: several SKUs roll up to one product, but minutes
        // and gigabyte-hours are not addable.
        var totals: [String: (product: String, unit: String, quantity: Double)] = [:]
        for item in items {
            guard let product = item["product"] as? String,
                let unit = item["unitType"] as? String,
                let quantity = item["quantity"] as? Double
            else { continue }
            totals["\(product).\(unit)", default: (product, unit, 0)].quantity += quantity
        }

        for (key, t) in totals.sorted(by: { $0.key < $1.key }) {
            metrics.append(
                Metric(
                    key: key, kind: .count, value: t.quantity, limit: nil,
                    window: .billingPeriod, resetsAt: nil,
                    label: "\(t.product) (\(t.unit))", unit: t.unit))
        }
        return metrics
    }
}
