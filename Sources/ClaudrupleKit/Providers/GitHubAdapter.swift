import Foundation

/// GitHub — billed usage for a user or organisation.
///
/// `GET /users/{username}/settings/billing/usage`, or the `/organizations/{org}/…` variant
/// when the credential names an org. Billing is uncapped, so the spend metric carries no
/// limit and never becomes a binding constraint.
public struct GitHubAdapter: UsageProviderAdapter {

    public static let id = "github"
    public static let displayName = "GitHub"

    public static let credentialSpec = CredentialSpec(
        keychainService: "claudruple.github",
        createURL: "https://github.com/settings/personal-access-tokens",
        // A leading @ selects the organisation endpoint; it cannot occur in a GitHub login,
        // so it is unambiguous.
        minimumScope: "\"username:token\" or \"@org:token\" — fine-grained PAT, Plan: read",
        scopeWarning:
            "A classic token with repo scope can read and write your code. Use a "
            + "fine-grained token limited to billing.")

    public static let capabilities = ProviderCapabilities(
        reportsSpend: true, reportsQuota: false)

    public init() {}

    public func request(credential: String) throws -> URLRequest {
        guard let sep = credential.firstIndex(of: ":") else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id,
                detail: "credential must be \"username:token\" or \"@org:token\"")
        }
        var account = String(credential[credential.startIndex..<sep])
        let token = String(credential[credential.index(after: sep)...])
        guard !account.isEmpty, !token.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "credential is missing an account or a token")
        }

        let isOrg = account.hasPrefix("@")
        if isOrg { account.removeFirst() }
        let path = isOrg
            ? "organizations/\(account)/settings/billing/usage"
            : "users/\(account)/settings/billing/usage"

        var r = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub versions its REST API by header. Omitting it opts into whatever becomes
        // current, which is how a working adapter breaks with no code change.
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    public func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["usageItems"] as? [[String: Any]]
        else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "no usageItems array — check the token's scope")
        }

        // netAmount is what is actually charged after plan allowances; grossAmount is list
        // price. Reporting gross overstates every bill that includes free minutes.
        let spend = items.reduce(0.0) { $0 + (($1["netAmount"] as? Double) ?? 0) }

        var metrics: [ProviderMetric] = [
            ProviderMetric(
                key: "spend", label: "Spend", kind: .currency,
                value: spend, limit: nil, unit: "USD", window: .billingPeriod)
        ]

        // Aggregate by product *and* unit. Several SKUs roll up to one product, but minutes
        // and gigabyte-hours are not addable, so the unit has to be part of the key.
        var totals: [String: (product: String, unit: String, quantity: Double)] = [:]
        for item in items {
            guard let product = item["product"] as? String,
                  let unit = item["unitType"] as? String,
                  let quantity = item["quantity"] as? Double
            else { continue }
            let key = "\(product).\(unit)"
            totals[key, default: (product, unit, 0)].quantity += quantity
        }

        for (key, t) in totals.sorted(by: { $0.key < $1.key }) {
            metrics.append(
                ProviderMetric(
                    key: key, label: "\(t.product) (\(t.unit))", kind: .count,
                    value: t.quantity, limit: nil, unit: t.unit, window: .billingPeriod))
        }

        // Unlike Twilio, an empty list is legitimate: a new account has no billable usage.
        return ProviderSnapshot(
            providerID: Self.id, accountLabel: nil, capturedAt: now, metrics: metrics)
    }
}
