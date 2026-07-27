import Foundation

/// ElevenLabs — character quota and voice slots.
///
/// `GET /v1/user/subscription` returns the whole subscription in one call, which makes this
/// the cleanest adapter in the set: one request, no pagination, no date-range arithmetic.
public struct ElevenLabsAdapter: UsageProviderAdapter {

    public static let id = "elevenlabs"
    public static let displayName = "ElevenLabs"

    public static let credentialSpec = CredentialSpec(
        keychainService: "claudruple.elevenlabs",
        createURL: "https://elevenlabs.io/app/settings/api-keys",
        minimumScope: "user_read",
        scopeWarning: "A key with text-to-speech scopes can spend your character quota.")

    public static let capabilities = ProviderCapabilities(
        reportsSpend: false, reportsQuota: true, reportsHistory: false)

    public init() {}

    public func request(credential: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        // Header, never a query parameter: URLs end up in logs, proxies and shell history.
        r.setValue(credential, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "response was not a JSON object")
        }

        var metrics: [ProviderMetric] = []

        // An auth failure returns valid JSON with none of these fields. Reporting that as
        // "0% used" would be actively misleading, so a response with no quota at all is an
        // error rather than an empty snapshot.
        if let used = root["character_count"] as? Double,
           let limit = root["character_limit"] as? Double
        {
            metrics.append(
                ProviderMetric(
                    key: "characters", label: "Characters", kind: .count,
                    value: used, limit: limit, unit: "chars",
                    window: .billingPeriod,
                    resetsAt: (root["next_character_count_reset_unix"] as? Double)
                        .map { Date(timeIntervalSince1970: $0) }))
        }

        // Free tiers omit the voice limit. Defaulting it to zero would render as a full
        // bar, so the metric is dropped instead.
        if let used = root["voice_slots_used"] as? Double,
           let limit = root["voice_limit"] as? Double, limit > 0
        {
            metrics.append(
                ProviderMetric(
                    key: "voice_slots", label: "Voice slots", kind: .count,
                    value: used, limit: limit, unit: "slots"))
        }

        guard !metrics.isEmpty else {
            throw ProviderError.unexpectedResponse(
                provider: Self.id, detail: "no quota fields present — check the API key")
        }

        return ProviderSnapshot(
            providerID: Self.id,
            accountLabel: root["tier"] as? String,
            capturedAt: now,
            metrics: metrics)
    }
}
