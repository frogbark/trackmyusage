import Foundation

/// The always-visible menu bar string.
public struct MenuBarSummary: Sendable, Equatable {
    public let title: String
    /// Any account sitting at its cap.
    public let isCritical: Bool

    public init(title: String, isCritical: Bool) {
        self.title = title
        self.isCritical = isCritical
    }

    /// How old a reading may be before it is marked rather than shown as current.
    public static let freshness: TimeInterval = 30 * 60

    public static func of(accounts: [AccountUsage], now: Date) -> MenuBarSummary {
        guard !accounts.isEmpty else {
            return MenuBarSummary(title: "—", isCritical: false)
        }

        // Order follows the caller's. Menu bar width is fixed real estate, and a title
        // that reshuffles as usage changes cannot be read at a glance.
        let parts = accounts.map { account -> String in
            guard let binding = account.binding(now: now) else { return "—" }
            let stale = !account.isFresh(now: now, limit: freshness)
            // A bare number reads as live. Admitting a reading is old beats presenting a
            // two-day-old figure as the current one.
            return "\(Int(binding.value.rounded()))%\(stale ? "?" : "")"
        }

        let critical = accounts.contains { ($0.binding(now: now)?.value ?? 0) >= 100 }
        return MenuBarSummary(title: parts.joined(separator: " · "), isCritical: critical)
    }
}

/// Decides when a usage change is worth interrupting someone for.
///
/// Notifying on every sample would mean one every five minutes. Notifying once and never
/// again would miss the next window. The rule is: announce each threshold once per window,
/// and re-arm when the window rolls.
public struct AlertPolicy: Sendable {
    private struct Key: Hashable {
        let account: String
        let metric: UsageMetric
    }

    /// Ascending utilisation levels worth announcing.
    public let thresholds: [Double]
    /// Highest threshold already announced for each account+metric, this window.
    private var announced: [Key: Double] = [:]

    public init(thresholds: [Double] = [80, 100]) {
        self.thresholds = thresholds.sorted()
    }

    public mutating func shouldNotify(
        account: String, metric: UsageMetric, value: Double
    ) -> Bool {
        let key = Key(account: account, metric: metric)
        let previouslyAnnounced = announced[key] ?? 0

        // A fall means the window rolled. The next climb is a new event, not a repeat —
        // without re-arming, the second half of the day goes unwarned.
        if value < previouslyAnnounced {
            announced[key] = 0
        }

        guard let crossed = thresholds.last(where: { value >= $0 }) else { return false }
        guard crossed > (announced[key] ?? 0) else { return false }

        announced[key] = crossed
        return true
    }
}
