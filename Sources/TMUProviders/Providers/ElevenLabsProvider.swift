import Foundation

/// ElevenLabs — character quota and voice slots.
///
/// `GET /v1/user/subscription` returns the whole subscription in one call: no pagination,
/// no date arithmetic, and both quotas come back with their caps attached.
public struct ElevenLabsProvider: UsageProvider {

    public static let endpoint = "https://api.elevenlabs.io/v1/user/subscription"

    public let id = "elevenlabs"
    public let credentialSpec = CredentialSpec(
        required: true,
        readOnlyScope: "user_read",
        instructions: "Profile → API Keys → create a key with user_read only.",
        createURL: "https://elevenlabs.io/app/settings/api-keys",
        scopeWarning: "A key with text-to-speech scopes can spend your character quota.")

    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        guard let url = URL(string: Self.endpoint) else {
            throw HTTPError.malformedResponse("bad endpoint")
        }
        // Header, never a query parameter: URLs reach logs, proxies and shell history.
        let response = try await http.get(url, headers: ["xi-api-key": secret ?? ""])
        guard response.isOK else { throw HTTPError.status(response.status) }

        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw HTTPError.malformedResponse("expected a JSON object") }

        var metrics: [Metric] = []

        if let used = root["character_count"] as? Double,
            let limit = root["character_limit"] as? Double
        {
            metrics.append(
                Metric(
                    key: "characters", kind: .absolute, value: used, limit: limit,
                    window: .billingPeriod,
                    resetsAt: (root["next_character_count_reset_unix"] as? Double)
                        .map(Date.init(timeIntervalSince1970:)),
                    label: "Characters", unit: "chars"))
        }

        // Free tiers omit the voice limit. Defaulting it to zero would draw a full bar,
        // so the metric is dropped rather than invented.
        if let used = root["voice_slots_used"] as? Double,
            let limit = root["voice_limit"] as? Double, limit > 0
        {
            metrics.append(
                Metric(
                    key: "voice_slots", kind: .absolute, value: used, limit: limit,
                    window: .none, resetsAt: nil, label: "Voice slots", unit: "slots"))
        }

        // An authentication failure returns valid JSON with none of these fields. Reporting
        // that as "0% used" would be worse than failing.
        guard !metrics.isEmpty else {
            throw HTTPError.malformedResponse("no quota fields — check the API key")
        }

        return ProviderReading(account: root["tier"] as? String, metrics: metrics)
    }
}
