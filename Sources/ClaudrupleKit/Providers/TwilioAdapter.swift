import Foundation

/// Twilio — spend and per-category usage.
///
/// `GET /2010-04-01/Accounts/{Sid}/Usage/Records.json`, HTTP Basic with the Account SID as
/// the username. Twilio is pay-as-you-go, so nothing here has a cap: the spend metric is
/// deliberately limitless and therefore never becomes a binding constraint.
public struct TwilioAdapter: UsageProviderAdapter {

    public static let id = "twilio"
    public static let displayName = "Twilio"

    public static let credentialSpec = CredentialSpec(
        keychainService: "claudruple.twilio",
        createURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
        // Twilio needs two values; they are stored as one "SID:token" string.
        minimumScope: "AccountSid:AuthToken — a read-only API Key SID/Secret also works",
        scopeWarning:
            "The main Auth Token can send messages and place calls. Prefer a restricted "
            + "API Key.")

    public static let capabilities = ProviderCapabilities(
        reportsSpend: true, reportsQuota: false, reportsHistory: false)

    public init() {}

    public func request(credential: String) throws -> URLRequest {
        // Split on the first separator only: the SID has a fixed shape but the token is
        // opaque and may itself contain colons.
        guard let sep = credential.firstIndex(of: ":") else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id,
                detail: "credential must be \"AccountSid:AuthToken\"")
        }
        let sid = String(credential[credential.startIndex..<sep])
        guard !sid.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "missing Account SID")
        }

        var r = URLRequest(
            url: URL(string:
                "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Usage/Records.json")!)
        // Basic auth header, never credentials in the URL — URLs reach logs and proxies.
        r.setValue(
            "Basic " + Data(credential.utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["usage_records"] as? [[String: Any]]
        else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "no usage_records array")
        }
        guard !records.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id,
                detail: "empty usage_records — an authenticated account always reports rows")
        }

        var metrics: [ProviderMetric] = []
        let currency = (records.first?["price_unit"] as? String)?.uppercased() ?? "USD"

        // Twilio reports a `totalprice` row alongside per-category rows. Summing everything
        // when that row is present would double-count.
        let total: Double
        if let totalRow = records.first(where: { $0["category"] as? String == "totalprice" }) {
            total = totalRow["price"] as? Double ?? 0
        } else {
            total = records.reduce(0) { $0 + (($1["price"] as? Double) ?? 0) }
        }

        metrics.append(
            ProviderMetric(
                key: "spend", label: "Spend", kind: .currency,
                value: total,
                limit: nil,  // pay-as-you-go: no cap, so no percentage and never binding
                unit: currency,
                window: .billingPeriod))

        for record in records {
            guard let category = record["category"] as? String, category != "totalprice"
            else { continue }
            // Accounts report dozens of categories, nearly all at zero; listing them all
            // buries the two that matter.
            guard let price = record["price"] as? Double, price > 0 else { continue }

            // `usage` and `count` arrive as strings while `price` is a number. Reading
            // usage as a Double yields nil and would silently report zero.
            let usage = (record["usage"] as? String).flatMap(Double.init)
                ?? (record["usage"] as? Double) ?? 0

            metrics.append(
                ProviderMetric(
                    key: category,
                    label: record["description"] as? String ?? category,
                    kind: .count,
                    value: usage,
                    limit: nil,
                    unit: record["usage_unit"] as? String,
                    window: .billingPeriod))
        }

        return ProviderSnapshot(
            providerID: Self.id, accountLabel: nil, capturedAt: now, metrics: metrics)
    }
}
