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

    /// Providers that cannot be built, and why.
    ///
    /// Distinct from merely pending. "Not written yet" is a promise; "there is no endpoint
    /// that reports this" is a fact about the vendor, and collapsing the two would have the
    /// project quietly owing work it cannot do. The reason is carried so the website can
    /// print it rather than showing an unexplained amber dot.
    public static let blocked: [String: String] = [
        "higgsfield": "no public usage endpoint",
        "openart": "no public usage endpoint",
    ]

    /// Providers with an adapter today.
    ///
    /// `claude` is included because its usage is read from local files and needs no adapter
    /// at all — leaving it out would undercount what actually works.
    public static var built: [String] {
        let ids = Set(all().map(\.id)).union(["claude"])
        return intended.filter { ids.contains($0) }
    }

    /// Intended, buildable, and not built yet.
    ///
    /// Derived rather than hand-maintained: a hardcoded "not yet implemented" list goes
    /// stale the moment an adapter lands, and then the tool is telling the user something
    /// untrue about itself.
    public static var pending: [String] {
        let done = Set(built)
        return intended.filter { !done.contains($0) && blocked[$0] == nil }
    }

    /// The three states, as the website renders them. One source, so the counts on the site
    /// cannot disagree with what the binary can actually do.
    public static var matrix: [(id: String, status: String, note: String?)] {
        intended.map { id in
            if built.contains(id) { return (id, "built", nil) }
            if let reason = blocked[id] { return (id, "blocked", reason) }
            return (id, "planned", nil)
        }
    }
}
