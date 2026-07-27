import Foundation

/// Stripe — account balance.
///
/// The odd one out: every other provider measures money going *out*, Stripe measures money
/// coming *in*. Its metrics carry no limit, so they can never become a binding constraint,
/// and callers must present them on their own axis rather than folding them into a spend
/// total — adding revenue to costs produces a number that means nothing.
public struct StripeAdapter: UsageProviderAdapter {

    public static let id = "stripe"
    public static let displayName = "Stripe"

    public static let credentialSpec = CredentialSpec(
        keychainService: "claudruple.stripe",
        createURL: "https://dashboard.stripe.com/apikeys",
        minimumScope: "restricted key with Balance: read",
        scopeWarning:
            "A full secret key can move money. Create a restricted key granting only "
            + "Balance read access.")

    public static let capabilities = ProviderCapabilities(
        reportsSpend: false, reportsQuota: false, reportsRevenue: true)

    public init() {}

    public func request(credential: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.stripe.com/v1/balance")!)
        // Stripe's Basic auth puts the key in the username half and leaves the password
        // empty — hence the trailing colon.
        r.setValue(
            "Basic " + Data("\(credential):".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization")
        return r
    }

    public func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "response was not a JSON object")
        }
        // Stripe reports auth failures as a well-formed body with an `error` object rather
        // than an empty one, so this has to be checked explicitly.
        if let error = root["error"] as? [String: Any] {
            throw ProviderError.unexpectedResponse(
                provider: Self.id,
                detail: error["message"] as? String ?? "API error")
        }
        guard root["object"] as? String == "balance" else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "expected a balance object")
        }

        var metrics: [ProviderMetric] = []

        // One entry per currency. Collapsing them would add euros to dollars.
        for (bucket, label) in [("available", "Available"), ("pending", "Pending")] {
            for entry in (root[bucket] as? [[String: Any]]) ?? [] {
                guard let minor = entry["amount"] as? Double,
                      let currency = entry["currency"] as? String
                else { continue }

                metrics.append(
                    ProviderMetric(
                        key: "\(bucket)_\(currency)",
                        label: "\(label) (\(currency.uppercased()))",
                        kind: .currency,
                        // Amounts arrive in minor units: 666670 is 6666.70. Skipping this
                        // gives a number wrong by 100× that still looks plausible.
                        value: minor / 100,
                        limit: nil,
                        unit: currency.uppercased()))
            }
        }

        guard !metrics.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "balance contained no currency entries")
        }

        return ProviderSnapshot(
            providerID: Self.id,
            accountLabel: (root["livemode"] as? Bool) == true ? "live" : "test",
            capturedAt: now,
            metrics: metrics)
    }
}
