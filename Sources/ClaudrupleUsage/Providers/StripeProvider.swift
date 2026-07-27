import Foundation

/// Stripe — account balance.
///
/// The odd one out: every other provider measures money going *out*, Stripe measures money
/// coming *in*. Nothing it reports carries a limit, so it can never become a binding
/// constraint, and callers must keep it on its own axis — adding revenue to costs produces
/// a number that means nothing.
public struct StripeProvider: UsageProvider {

    public static let endpoint = "https://api.stripe.com/v1/balance"

    public let id = "stripe"
    public let credentialSpec = CredentialSpec(
        required: true,
        readOnlyScope: "restricted key with Balance: read",
        instructions: "Developers → API keys → create a restricted key, Balance read only.",
        createURL: "https://dashboard.stripe.com/apikeys",
        scopeWarning: "A full secret key can move money. Use a restricted key.")

    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        guard let url = URL(string: Self.endpoint) else {
            throw HTTPError.malformedResponse("bad endpoint")
        }
        // Stripe's Basic auth puts the key in the username half and leaves the password
        // empty — hence the trailing colon.
        let auth = "Basic " + Data("\(secret ?? ""):".utf8).base64EncodedString()
        let response = try await http.get(url, headers: ["Authorization": auth])
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw HTTPError.malformedResponse("expected a JSON object") }

        // Stripe reports auth failures as a well-formed body carrying an `error` object
        // rather than an empty one, so this has to be checked explicitly.
        if let error = root["error"] as? [String: Any] {
            throw HTTPError.malformedResponse(error["message"] as? String ?? "API error")
        }
        guard root["object"] as? String == "balance" else {
            throw HTTPError.malformedResponse("expected a balance object")
        }

        var metrics: [Metric] = []

        // One entry per currency. Collapsing them would add euros to dollars.
        for (bucket, label) in [("available", "Available"), ("pending", "Pending")] {
            for entry in (root[bucket] as? [[String: Any]]) ?? [] {
                guard let minor = entry["amount"] as? Double,
                    let currency = entry["currency"] as? String
                else { continue }

                metrics.append(
                    Metric(
                        key: "\(bucket)_\(currency)", kind: .currency,
                        // Amounts arrive in minor units: 666670 is 6666.70. Missing this
                        // gives a figure wrong by 100x that still looks plausible.
                        value: minor / 100,
                        limit: nil, window: .none, resetsAt: nil,
                        label: "\(label) (\(currency.uppercased()))",
                        unit: currency.uppercased()))
            }
        }

        guard !metrics.isEmpty else {
            throw HTTPError.malformedResponse("balance contained no currency entries")
        }

        return ProviderReading(
            account: (root["livemode"] as? Bool) == true ? "live" : "test",
            metrics: metrics)
    }
}
