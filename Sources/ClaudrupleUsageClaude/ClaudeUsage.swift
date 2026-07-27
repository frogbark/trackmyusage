import ClaudrupleKit
import ClaudrupleUsage
import Foundation

/// Maps Claude Desktop's own accounting onto the provider-neutral shape.
///
/// Tier 1, and the only provider that needs no credential: the data is already on disk in
/// each instance's profile, so it works offline and backfills the existing history the first
/// time it runs. It is deliberately not a `UsageProviderAdapter` — there is no request to
/// build and no response to parse, and forcing a local file through an HTTP-shaped protocol
/// would mean inventing both.
public enum ClaudeUsage {

    public static let providerID = "claude"

    /// The file each instance writes its own accounting to.
    public static let historyFilename = "plan-usage-history.json"

    /// Reads one instance's profile.
    ///
    /// A malformed file is reported as unavailable rather than thrown. Claude writes this
    /// file from another process on its own schedule, so reading a half-written one is
    /// routine rather than exceptional — and one torn read must not take down the render
    /// for every other account.
    public static func snapshot(name: String, bundleID: String, profileURL: URL)
        -> ProviderSnapshot
    {
        let file = profileURL.appendingPathComponent(historyFilename)
        do {
            let history = try UsageHistory.parse(contentsOf: file)
            return snapshot(
                of: AccountUsage(instanceName: name, bundleID: bundleID, history: history))
        } catch {
            return ProviderSnapshot(
                providerID: providerID, accountLabel: name, capturedAt: .distantPast,
                status: .unavailable("\(error)"), metrics: [])
        }
    }

    /// Every Claude instance on this machine.
    public static func discover() -> [ProviderSnapshot] {
        InstanceLocator.discover().map {
            snapshot(name: $0.name, bundleID: $0.bundleID, profileURL: $0.profileURL)
        }
    }

    public static func snapshot(of account: AccountUsage) -> ProviderSnapshot {
        guard let latest = account.history.samples.last else {
            return ProviderSnapshot(
                providerID: providerID, accountLabel: account.instanceName,
                capturedAt: .distantPast,
                status: .unavailable("no usage history yet"), metrics: [])
        }

        // Sorted because a dictionary is not ordered and everything downstream — the
        // rendered wallpaper especially — must be stable between runs. A gauge whose rows
        // reshuffle on each sample cannot be read at a glance, and golden-file tests over
        // unordered output are flaky rather than useful.
        let metrics = latest.metrics
            .map { normalize($0.key, value: $0.value) }
            .sorted { $0.key < $1.key }

        return ProviderSnapshot(
            providerID: providerID, accountLabel: account.instanceName,
            capturedAt: latest.timestamp, status: .ok, metrics: metrics)
    }

    /// One rule decides whether a reading may drive a decision: does it have a window?
    ///
    /// A windowed metric is a real cap, reported by the file as a utilisation percentage.
    /// Everything else — the pay-as-you-go credit pool, a code this build does not
    /// recognise — has no denominator and no known semantics, so it carries no limit and
    /// can therefore never be the binding metric. That is the same exclusion `Steering`
    /// makes, expressed structurally here instead of restated as a second filter.
    private static func normalize(_ metric: UsageMetric, value: Double) -> ProviderMetric {
        guard let window = metric.window else {
            return ProviderMetric(
                key: key(of: metric), label: metric.displayName, kind: .count,
                value: value, limit: nil, unit: nil, window: .none)
        }
        return ProviderMetric(
            key: key(of: metric), label: metric.displayName, kind: .percentOfLimit,
            value: value, limit: nil, unit: nil, window: .rolling(window))
    }

    /// Stable keys, matching the names in the app's own limit map rather than inventing
    /// new ones — a stored history stays readable against a future build.
    private static func key(of metric: UsageMetric) -> String {
        switch metric {
        case .fiveHour: return "five_hour"
        case .sevenDay: return "seven_day"
        case .sevenDayOpus: return "seven_day_opus"
        case .sevenDaySonnet: return "seven_day_sonnet"
        case .sevenDayCowork: return "seven_day_cowork"
        case .sevenDayOAuthApps: return "seven_day_oauth_apps"
        case .sevenDayOmelette: return "seven_day_omelette"
        case .omellettePromotional: return "omelette_promotional"
        case .extraUsage: return "extra_usage"
        case .unknown(let raw): return raw
        }
    }
}
