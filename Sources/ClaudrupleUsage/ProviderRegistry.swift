import Foundation

/// Every provider this build can talk to.
///
/// Adapters are absent rather than stubbed when their response shape has not been
/// confirmed. A parser written from a remembered API shape is indistinguishable from a
/// correct one until it reports the wrong number, and a usage dashboard that is quietly
/// wrong is worse than one that is honestly incomplete.
public enum ProviderRegistry {

    public static func all(http: HTTPClient = URLSessionHTTPClient()) -> [any UsageProvider] {
        [
            ElevenLabsProvider(http: http),
            GitHubProvider(http: http),
            StripeProvider(http: http),
            TwilioProvider(http: http),
        ]
    }

    public static func provider(
        id: String, http: HTTPClient = URLSessionHTTPClient()
    ) -> (any UsageProvider)? {
        all(http: http).first { $0.id == id }
    }

    /// Every provider the project intends to cover.
    public static let intended = [
        "claude", "openai", "github", "vercel", "twilio", "elevenlabs", "sentry",
        "posthog", "firecrawl", "resend", "stripe", "supabase", "modal", "inngest",
        "hostinger", "higgsfield", "openart",
    ]

    /// Intended providers with no adapter yet.
    ///
    /// Derived rather than hand-maintained: a hardcoded "not yet implemented" list goes
    /// stale the moment an adapter lands, and then the tool is telling the user something
    /// untrue about itself. `claude` is excluded because its usage is read from local
    /// files and needs no adapter.
    public static var pending: [String] {
        let built = Set(all().map(\.id)).union(["claude"])
        return intended.filter { !built.contains($0) }
    }
}
