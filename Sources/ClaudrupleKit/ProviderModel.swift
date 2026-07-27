import Foundation

/// What a number means. Kept explicit so a view never has to guess whether 80 is dollars,
/// events or per cent.
public enum MetricKind: String, Sendable, Equatable {
    case percentOfLimit
    case currency
    case count
}

/// The reporting period a metric belongs to.
public enum MetricWindow: Sendable, Equatable {
    case rolling(TimeInterval)
    case calendarMonth
    case billingPeriod
    case none
}

/// One measurement from one provider.
public struct ProviderMetric: Sendable, Equatable {
    public let key: String
    public let label: String
    public let kind: MetricKind
    public let value: Double
    /// The cap, when the provider publishes one. Absent means uncapped, not unknown-so-
    /// assume-something.
    public let limit: Double?
    public let unit: String?
    public let window: MetricWindow
    public let resetsAt: Date?

    public init(
        key: String, label: String, kind: MetricKind,
        value: Double, limit: Double?, unit: String?,
        window: MetricWindow = .none, resetsAt: Date? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.value = value
        self.limit = limit
        self.unit = unit
        self.window = window
        self.resetsAt = resetsAt
    }

    /// Percentage of the cap consumed, or nil when there is no cap to measure against.
    ///
    /// Derived rather than reported, so a provider cannot hand us an inconsistent pair.
    /// Uncapped spend deliberately yields nil: manufacturing a percentage against a budget
    /// the user never set would feed a fabricated number straight into an alert threshold.
    public var utilization: Double? {
        if kind == .percentOfLimit { return value }
        guard let limit, limit > 0 else { return nil }
        return value / limit * 100
    }

    public var formattedValue: String {
        switch kind {
        case .percentOfLimit:
            return String(format: "%g%%", value)
        case .currency:
            return String(format: "%.2f%@", value, unit.map { " \($0)" } ?? "")
        case .count:
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            let n = f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
            return n + (unit.map { " \($0)" } ?? "")
        }
    }
}

/// Everything one provider reported at one moment.
public struct ProviderSnapshot: Sendable, Equatable {
    public let providerID: String
    /// Org, team or account name, when the API exposes one.
    public let accountLabel: String?
    public let capturedAt: Date
    public let metrics: [ProviderMetric]

    public init(
        providerID: String, accountLabel: String?, capturedAt: Date, metrics: [ProviderMetric]
    ) {
        self.providerID = providerID
        self.accountLabel = accountLabel
        self.capturedAt = capturedAt
        self.metrics = metrics
    }

    /// The metric closest to its cap.
    ///
    /// Only capped metrics compete. An uncapped $9,999 spend must not outrank a quota at
    /// 95% merely because its raw number is larger — they are not on the same scale, and
    /// comparing them is the mistake this type exists to prevent.
    public var binding: ProviderMetric? {
        metrics
            .filter { $0.utilization != nil }
            .max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
    }
}

/// How to obtain the least-privileged token a provider will accept.
///
/// Carried in code rather than prose so the setup flow, the README and `doctor` all read
/// the same source instead of drifting apart.
public struct CredentialSpec: Sendable, Equatable {
    public let keychainService: String
    /// Where the user mints the token.
    public let createURL: String
    /// The minimum scope that makes the adapter work.
    public let minimumScope: String
    /// What a broader token would allow, stated plainly so the trade-off is visible.
    public let scopeWarning: String?

    public init(
        keychainService: String, createURL: String,
        minimumScope: String, scopeWarning: String? = nil
    ) {
        self.keychainService = keychainService
        self.createURL = createURL
        self.minimumScope = minimumScope
        self.scopeWarning = scopeWarning
    }
}

/// What a provider can actually tell us. Set honestly — the UI uses it to explain gaps
/// rather than showing an empty panel.
public struct ProviderCapabilities: Sendable, Equatable {
    public let reportsSpend: Bool
    public let reportsQuota: Bool
    /// Money coming *in*. Distinct from spend because the two must never be summed.
    public let reportsRevenue: Bool
    public let reportsHistory: Bool

    public init(
        reportsSpend: Bool, reportsQuota: Bool,
        reportsRevenue: Bool = false, reportsHistory: Bool = false
    ) {
        self.reportsSpend = reportsSpend
        self.reportsQuota = reportsQuota
        self.reportsRevenue = reportsRevenue
        self.reportsHistory = reportsHistory
    }

    /// Human-readable summary, so callers do not each invent their own wording.
    public var summary: String {
        var parts: [String] = []
        if reportsQuota { parts.append("quota") }
        if reportsSpend { parts.append("spend") }
        if reportsRevenue { parts.append("revenue") }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

/// A metered service.
///
/// Split into request-building and response-parsing on purpose. Parsing is where the risk
/// and the churn live, and keeping it a pure function of `Data` means every adapter can be
/// verified against a recorded fixture — so a contributor can add a provider without
/// holding a paid account for it.
public protocol UsageProviderAdapter: Sendable {
    static var id: String { get }
    static var displayName: String { get }
    static var credentialSpec: CredentialSpec { get }
    static var capabilities: ProviderCapabilities { get }

    func request(credential: String) throws -> URLRequest
    func parse(_ data: Data, now: Date) throws -> ProviderSnapshot
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case unexpectedResponse(provider: String, detail: String)
    case missingCredential(provider: String)

    public var description: String {
        switch self {
        case .unexpectedResponse(let p, let d):
            return "\(p): unexpected response — \(d)"
        case .missingCredential(let p):
            return "\(p): no credential stored"
        }
    }
}

// Instance-level mirrors of the static requirements, so adapters remain usable as
// existentials (`any UsageProviderAdapter`) in a registry without each call site having
// to recover the concrete type.
extension UsageProviderAdapter {
    public var id: String { Self.id }
    public var displayName: String { Self.displayName }
    public var credentialSpec: CredentialSpec { Self.credentialSpec }
    public var capabilities: ProviderCapabilities { Self.capabilities }
}

/// Every adapter this build knows about.
///
/// One verified entry today. The others are deliberately absent rather than stubbed:
/// a parser written from a remembered API shape looks identical to a correct one until it
/// silently reports the wrong number, and a usage tool that is quietly wrong is worse than
/// one that is honestly incomplete. `claudruple provider probe` captures a real response so
/// each parser can be written against fact.
public enum ProviderRegistry {
    public static let all: [any UsageProviderAdapter] = [
        ElevenLabsAdapter(),
        TwilioAdapter(),
        StripeAdapter(),
        GitHubAdapter(),
    ]

    public static func adapter(id: String) -> (any UsageProviderAdapter)? {
        all.first { $0.id == id }
    }

    /// Every provider this project intends to cover.
    ///
    /// `pending` is derived from this rather than maintained by hand — a hardcoded
    /// "not yet implemented" list goes stale the moment an adapter lands, and then the
    /// tool is telling the user something untrue about itself.
    public static let intended = [
        "claude", "openai", "github", "vercel", "twilio", "elevenlabs", "sentry",
        "posthog", "firecrawl", "resend", "stripe", "supabase", "modal", "inngest",
        "hostinger", "higgsfield", "openart",
    ]

    /// Intended providers with no adapter yet. `claude` is excluded: it needs no adapter
    /// because its usage is read from local files.
    public static var pending: [String] {
        let built = Set(all.map(\.id)).union(["claude"])
        return intended.filter { !built.contains($0) }
    }
}
