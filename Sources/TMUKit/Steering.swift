import Foundation
import TMUDesign

/// One account's usage, paired with the instance that holds it.
public struct AccountUsage: Sendable, Equatable {
    public let instanceName: String
    public let bundleID: String
    public let history: UsageHistory

    public init(instanceName: String, bundleID: String, history: UsageHistory) {
        self.instanceName = instanceName
        self.bundleID = bundleID
        self.history = history
    }

    /// The limit closest to its cap — the one that will actually stop work.
    ///
    /// Only real limits count. `extraUsage` is a pay-as-you-go credit pool rather than a
    /// cap, and an unrecognised code has unknown semantics; letting either bind would mean
    /// a credit balance or a future field could trigger advice to abandon a session.
    public func binding(now: Date) -> (metric: UsageMetric, value: Double)? {
        guard let latest = history.samples.last else { return nil }
        return latest.metrics
            .filter { $0.key.window != nil }
            .max { $0.value < $1.value }
            .map { (metric: $0.key, value: $0.value) }
    }

    /// Percentage points left before the binding limit stops work.
    public func headroom(now: Date) -> Double {
        guard let b = binding(now: now) else { return 0 }
        return max(0, 100 - b.value)
    }

    /// Whether the newest reading is recent enough to act on.
    public func isFresh(now: Date, limit: TimeInterval) -> Bool {
        guard let latest = history.samples.last else { return false }
        return now.timeIntervalSince(latest.timestamp) <= limit
    }
}

/// What to do about the current usage picture.
public struct SteeringAdvice: Sendable, Equatable {
    public enum Urgency: Sendable, Equatable {
        /// Nothing worth saying.
        case none
        /// The active account is nearing its binding limit.
        case approaching
        /// The active account has hit it.
        case exhausted
    }

    public let urgency: Urgency
    /// The limit driving the urgency, on the active account.
    public let bindingMetric: UsageMetric?
    public let bindingValue: Double
    /// An account with materially more headroom, or nil when there is nowhere better.
    public let recommended: String?
    public let reason: String
}

public enum Steering {

    public struct Thresholds: Sendable {
        /// Warn from here up. Shared with the wallpaper and the notifications, so all three
        /// agree about what "approaching" means.
        public var approaching: Double = TMUDesign.Thresholds.warn
        /// Nothing left.
        public var exhausted: Double = TMUDesign.Thresholds.over
        /// Extra headroom an alternative must offer before it is worth moving.
        ///
        /// Without this the tool oscillates between two nearly-full accounts, suggesting a
        /// move for four points of advantage. Advice that fires constantly gets muted, and
        /// a muted tool cannot warn about anything.
        public var switchMargin: Double = 15
        /// How old a reading may be and still support a *recommendation*. An account last
        /// seen two days ago may have been consumed since.
        ///
        /// Deliberately not `TMUDesign.Thresholds.staleAfter` (30 min). That one decides
        /// whether to mark a number as stale on screen; this one decides whether an account
        /// is a credible place to send someone. A reading two hours old is worth showing
        /// with a caveat and still worth switching to.
        public var recommendationHorizon: TimeInterval = 6 * 3600

        public init() {}
    }

    public static func advise(
        accounts: [AccountUsage],
        activeInstance: String?,
        now: Date,
        thresholds: Thresholds = Thresholds()
    ) -> SteeringAdvice {
        let active = accounts.first { $0.instanceName == activeInstance }
        let binding = active?.binding(now: now)
        let value = binding?.value ?? 0

        let urgency: SteeringAdvice.Urgency
        if active == nil {
            urgency = .none
        } else if value >= thresholds.exhausted {
            urgency = .exhausted
        } else if value >= thresholds.approaching {
            urgency = .approaching
        } else {
            urgency = .none
        }

        // Rank only accounts that are not the active one and whose readings are recent
        // enough to trust.
        let best =
            accounts
            .filter { $0.instanceName != activeInstance }
            .filter { $0.isFresh(now: now, limit: thresholds.recommendationHorizon) }
            .max { $0.headroom(now: now) < $1.headroom(now: now) }

        var recommended: String?
        if let best {
            let gain = best.headroom(now: now) - (active?.headroom(now: now) ?? 0)
            let worthIt = gain >= thresholds.switchMargin && best.headroom(now: now) > 0
            // With nothing focused there is no session to abandon, so surface the best
            // option on its own merits rather than on a margin over nothing.
            if active == nil ? best.headroom(now: now) > 0 : worthIt {
                recommended = best.instanceName
            }
        }

        return SteeringAdvice(
            urgency: urgency,
            bindingMetric: binding?.metric,
            bindingValue: value,
            recommended: recommended,
            reason: describe(urgency: urgency, binding: binding, recommended: recommended))
    }

    private static func describe(
        urgency: SteeringAdvice.Urgency,
        binding: (metric: UsageMetric, value: Double)?,
        recommended: String?
    ) -> String {
        guard let binding else { return "no usage data" }
        let limit = binding.metric.displayName.lowercased()

        switch urgency {
        case .none:
            return recommended.map { "\($0) has more headroom" }
                ?? "\(limit) at \(Int(binding.value))%"
        case .approaching:
            let head = "\(limit) at \(Int(binding.value))%"
            return recommended.map { "\(head) — \($0) has more headroom" }
                ?? "\(head) — no account has meaningfully more"
        case .exhausted:
            let head = "\(limit) exhausted"
            return recommended.map { "\(head) — switch to \($0)" }
                ?? "\(head) — every account is spent"
        }
    }
}
