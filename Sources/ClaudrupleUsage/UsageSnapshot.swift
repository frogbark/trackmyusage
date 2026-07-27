import Foundation

/// Everything one provider had to say at one moment.
public struct UsageSnapshot: Sendable, Equatable {

    /// Whether this snapshot carries a measurement at all.
    ///
    /// Kept distinct from an empty metric list so the difference between "we asked and the
    /// answer was zero" and "we could not ask" survives all the way to the screen.
    public enum Status: Sendable, Equatable {
        case ok
        /// No usage API, or the provider declined to answer. Carries the reason so the UI
        /// can explain itself rather than showing a blank.
        case unavailable(String)
        /// No credential, or one the provider rejected.
        case unauthorized
    }

    public let provider: String
    /// Which account, for providers that have more than one. Nil where the credential
    /// identifies the account implicitly.
    public let account: String?
    public let observedAt: Date
    public let status: Status
    public let metrics: [Metric]

    public init(
        provider: String, account: String?, observedAt: Date,
        status: Status, metrics: [Metric]
    ) {
        self.provider = provider
        self.account = account
        self.observedAt = observedAt
        self.status = status
        self.metrics = metrics
    }

    public var isReporting: Bool { status == .ok }

    /// The metric nearest its cap — the one that will actually stop work.
    ///
    /// Only capped metrics are eligible. Revenue is the case that forces this: it is a
    /// large number with no limit, and without the filter it would sort straight to the top
    /// and be announced as the thing about to run out.
    public var binding: Metric? {
        guard isReporting else { return nil }
        return metrics
            .filter { $0.utilization != nil }
            .max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
    }
}
