import Foundation

/// What a metric's `value` means.
///
/// The kind exists because seventeen providers do not agree on how to report usage. One
/// gives a percentage, one a raw count against a quota, one a dollar figure with no cap at
/// all. Normalising them to a single number would require inventing denominators; carrying
/// the kind lets each stay honest and lets the renderer decide how to draw it.
public enum MetricKind: Sendable, Equatable {
    /// `value` is already a utilisation percentage, 0–100.
    case percentOfLimit
    /// `value` is a raw quantity, meaningful against `limit`.
    case absolute
    /// `value` is money.
    case currency
    /// `value` is a count of things — seats, projects, indexes.
    case count
}

/// The period a metric measures over, and therefore when it resets.
public enum MetricWindow: Sendable, Equatable {
    case rolling(TimeInterval)
    case calendarMonth
    case billingPeriod
    /// A standing figure that does not reset — seat count, current balance.
    case none
}

/// One reading from one provider.
public struct Metric: Sendable, Equatable {
    public let key: String
    public let kind: MetricKind
    public let value: Double
    /// The cap, where one is known. Nil is common and load-bearing: revenue has no cap,
    /// and several providers expose consumption without exposing the quota it counts against.
    public let limit: Double?
    public let window: MetricWindow
    public let resetsAt: Date?

    public init(
        key: String, kind: MetricKind, value: Double,
        limit: Double?, window: MetricWindow, resetsAt: Date?
    ) {
        self.key = key
        self.kind = kind
        self.value = value
        self.limit = limit
        self.window = window
        self.resetsAt = resetsAt
    }

    /// How full this metric is, 0–100, or nil when there is nothing to be a percentage of.
    ///
    /// Not clamped. Overage is real, and flattening 150% to 100% erases the distinction
    /// between "at the cap" and "well past it" exactly when it matters most.
    public var utilization: Double? {
        if case .percentOfLimit = kind { return value }
        // A quota of zero is a real answer on a free tier, and dividing by it yields
        // infinity — which then sorts as the binding limit and pins every gauge to full.
        guard let limit, limit > 0 else { return nil }
        return value / limit * 100
    }

    public var isOverLimit: Bool { (utilization ?? 0) >= 100 }
}
