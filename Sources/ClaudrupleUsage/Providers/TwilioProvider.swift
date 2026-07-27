import Foundation

/// Twilio — spend and per-category usage.
///
/// `GET /2010-04-01/Accounts/{Sid}/Usage/Records.json`, HTTP Basic with the Account SID as
/// the username. Pay-as-you-go, so nothing here carries a cap and none of it can become a
/// binding constraint.
public struct TwilioProvider: UsageProvider {

    public let id = "twilio"
    public let credentialSpec = CredentialSpec(
        required: true,
        readOnlyScope: "API Key SID/Secret with read access",
        instructions: "Store as \"AccountSid:AuthToken\", or \"KeySid:KeySecret\".",
        createURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
        scopeWarning:
            "The main Auth Token can send messages and place calls. Prefer a restricted "
            + "API Key.")

    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        // Split on the first separator only: the SID has a fixed shape, the token is opaque
        // and may itself contain colons.
        guard let secret, let sep = secret.firstIndex(of: ":") else {
            throw HTTPError.malformedResponse("credential must be \"AccountSid:AuthToken\"")
        }
        let sid = String(secret[secret.startIndex..<sep])
        guard !sid.isEmpty else {
            throw HTTPError.malformedResponse("missing Account SID")
        }
        guard let url = URL(string:
            "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Usage/Records.json")
        else { throw HTTPError.malformedResponse("bad Account SID") }

        let auth = "Basic " + Data(secret.utf8).base64EncodedString()
        let response = try await http.get(url, headers: ["Authorization": auth])
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard
            let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let records = root["usage_records"] as? [[String: Any]]
        else { throw HTTPError.malformedResponse("expected a `usage_records` array") }
        guard !records.isEmpty else {
            throw HTTPError.malformedResponse("empty usage_records — an account always reports rows")
        }

        let currency = (records.first?["price_unit"] as? String)?.uppercased() ?? "USD"

        // Twilio reports a `totalprice` row alongside per-category rows. Summing everything
        // when that row is present double-counts.
        let total: Double
        if let row = records.first(where: { $0["category"] as? String == "totalprice" }) {
            total = row["price"] as? Double ?? 0
        } else {
            total = records.reduce(0) { $0 + (($1["price"] as? Double) ?? 0) }
        }

        var metrics = [
            Metric(
                key: "spend", kind: .currency, value: total,
                limit: nil,  // pay-as-you-go: no cap, so no percentage and never binding
                window: .billingPeriod, resetsAt: nil, label: "Spend", unit: currency)
        ]

        for record in records {
            guard let category = record["category"] as? String, category != "totalprice"
            else { continue }
            // An account reports dozens of categories, nearly all at zero; listing them all
            // buries the two that matter.
            guard let price = record["price"] as? Double, price > 0 else { continue }

            // `usage` and `count` arrive as strings while `price` is a number. Reading
            // usage as a Double yields nil and would silently report zero.
            let usage = (record["usage"] as? String).flatMap(Double.init)
                ?? (record["usage"] as? Double) ?? 0

            metrics.append(
                Metric(
                    key: category, kind: .count, value: usage, limit: nil,
                    window: .billingPeriod, resetsAt: nil,
                    label: record["description"] as? String ?? category,
                    unit: record["usage_unit"] as? String))
        }

        return ProviderReading(metrics: metrics)
    }
}
