import Foundation
import TMUDesign
import TMUProviders

/// Everything the surfaces draw, decided once.
///
/// The widget, the menu bar pill, the popover and the instances window all render *this*
/// value rather than each deriving their own rows from raw snapshots. That is the only
/// structural guarantee that they agree: the wallpaper this replaced built rows in a private
/// function inside its renderer while the menu bar built different rows from a different
/// source, and nothing stopped them disagreeing about what "62%" meant.
///
/// It is also the wire format between the app and the widget. The app writes this to the App
/// Group container and the sandboxed extension reads it — see `WidgetPublisher`.
///
/// `Codable` because it is also the golden-file format for tests. Snapshotting this catches
/// every content regression — a wrong row, a lost order, a missing `?`, a misclassified
/// state — in a diff a person can actually read, and stays stable when pure geometry changes.
public struct TelemetryModel: Codable, Equatable, Sendable {

    public let claude: [AccountRow]
    public let services: [ServiceRow]
    public let renewals: [Renewal]
    public let attention: Attention
    public let generatedAt: Date
    /// The zone `generatedAt` is drawn in.
    ///
    /// Part of the model because the clock on the widget is content, and content belongs to
    /// the thing every surface renders rather than to whichever process happens to draw it.
    /// Carrying it here is what lets the demo renders be reproducible by construction instead
    /// of by exporting TZ before running the generator.
    public let timeZone: TimeZone

    /// A Claude Desktop or Claude Code account.
    public struct AccountRow: Codable, Equatable, Sendable {
        public let name: String
        public let utilization: Double?
        /// Already carries the `?` when stale. Produced through `Freshness.mark`.
        public let display: String
        public let state: UsageState
        public let isStale: Bool
        /// "5-hour", "Weekly" — what the percentage is a percentage *of*.
        public let windowLabel: String?
        public let resetsAt: Date?
    }

    /// A metered service.
    public struct ServiceRow: Codable, Equatable, Sendable {
        public let name: String
        public let utilization: Double?
        public let display: String
        public let state: UsageState
        public let isStale: Bool
        /// Recent readings, oldest first, for the rail's sparkline.
        ///
        /// Empty or one-element means *draw nothing*. A single point rendered as a flat line
        /// is a claim about a trend we do not have, and this codebase already refuses to
        /// print a forecast it cannot measure.
        public let sparkline: [Double]
        public let resetsAt: Date?
    }

    /// A billing period about to roll over.
    public struct Renewal: Codable, Equatable, Sendable {
        public let name: String
        public let date: Date
        public let daysAway: Int
        public let state: UsageState
    }

    /// How loud the surface drawing this should be.
    ///
    /// Derived from the readings, never chosen. Exposing it as a setting produces a
    /// permanently-alert desktop, which is the same as no signal at all — the quiet state
    /// only means something because it is the usual one.
    public enum Attention: String, Codable, Equatable, Sendable {
        case quiet
        case alert
    }

    /// Providers whose snapshots are treated as accounts rather than services.
    static let accountProviders: Set<String> = ["claude", "claude-code"]

    /// How far ahead a renewal is worth mentioning. The large widget lists what is inside it.
    static let renewalHorizon: TimeInterval = 30 * 24 * 3600

    // MARK: - Building

    /// The single point where raw snapshots become something drawable.
    ///
    /// This replaced a row-builder private to the wallpaper renderer, which threw away
    /// everything except name, utilisation, display and state — so `resetsAt`, `unit`,
    /// staleness and every non-binding metric were collected by the adapters and silently
    /// discarded one function before they could be used.
    public static func build(
        snapshots: [UsageSnapshot],
        history: [String: [Double]] = [:],
        now: Date,
        timeZone: TimeZone = .current
    ) -> TelemetryModel {
        var accounts: [AccountRow] = []
        var services: [ServiceRow] = []

        for snapshot in snapshots {
            let reading = Reading(snapshot, now: now)
            if accountProviders.contains(snapshot.provider) {
                accounts.append(
                    AccountRow(
                        name: reading.name, utilization: reading.utilization,
                        display: reading.display, state: reading.state,
                        isStale: reading.isStale, windowLabel: reading.windowLabel,
                        resetsAt: reading.resetsAt))
            } else {
                services.append(
                    ServiceRow(
                        name: reading.name, utilization: reading.utilization,
                        display: reading.display, state: reading.state,
                        isStale: reading.isStale,
                        sparkline: history[reading.name] ?? history[snapshot.provider] ?? [],
                        resetsAt: reading.resetsAt))
            }
        }

        // Stable order, always, by name. Ranking by utilisation would reshuffle every panel
        // on every sample, and a list whose rows move cannot be read at a glance. The two
        // places that *do* rank — the popover's SERVICES section and the compact card's
        // headline picks — sort a copy at the point of use.
        accounts.sort { $0.name < $1.name }
        services.sort { $0.name < $1.name }

        return TelemetryModel(
            claude: accounts,
            services: services,
            renewals: renewals(from: snapshots, now: now),
            attention: attention(accounts: accounts, services: services),
            generatedAt: now,
            timeZone: timeZone)
    }

    /// Quiet unless something is actually near its limit.
    private static func attention(accounts: [AccountRow], services: [ServiceRow]) -> Attention {
        let peak =
            (accounts.compactMap(\.utilization) + services.compactMap(\.utilization))
            .max() ?? 0
        return peak >= Thresholds.warn ? .alert : .quiet
    }

    private static func renewals(from snapshots: [UsageSnapshot], now: Date) -> [Renewal] {
        snapshots.compactMap { snapshot -> Renewal? in
            let reading = Reading(snapshot, now: now)
            guard let date = reading.resetsAt else { return nil }
            let seconds = date.timeIntervalSince(now)
            // A reset in the past is a stale reading rather than a renewal; one beyond the
            // horizon would not fit on the axis the card draws.
            guard seconds >= 0, seconds <= renewalHorizon else { return nil }
            return Renewal(
                name: reading.name,
                date: date,
                daysAway: Int((seconds / 86400).rounded()),
                state: reading.state)
        }
        .sorted { $0.date < $1.date }
    }
}

/// One snapshot, interpreted. Shared by both row kinds so they cannot classify differently.
private struct Reading {
    let name: String
    let utilization: Double?
    let display: String
    let state: UsageState
    let isStale: Bool
    let windowLabel: String?
    let resetsAt: Date?

    init(_ snapshot: UsageSnapshot, now: Date) {
        // `account ?? provider`: several accounts of one provider is the situation this
        // project exists to manage, and labelling every one of them "claude" makes every
        // surface useless for exactly its main case.
        self.name = snapshot.account ?? snapshot.provider
        self.isStale = Freshness.isStale(age: snapshot.age(at: now))

        guard snapshot.isReporting else {
            self.utilization = nil
            self.display = "no data"
            self.state = .nodata
            self.windowLabel = nil
            self.resetsAt = nil
            return
        }

        if let binding = snapshot.binding, let utilization = binding.utilization {
            self.utilization = utilization
            self.state = UsageState.classify(utilization: utilization)
            self.display = Freshness.mark(
                "\(Format.grouped(utilization.rounded()))%", stale: isStale)
            self.windowLabel = binding.label
            self.resetsAt = binding.resetsAt ?? snapshot.metrics.compactMap(\.resetsAt).min()
            return
        }

        // Reporting, but nothing here has a ceiling — show the reading in its own units.
        guard let first = snapshot.metrics.first else {
            self.utilization = nil
            self.display = "no data"
            self.state = .nodata
            self.windowLabel = nil
            self.resetsAt = nil
            return
        }
        self.utilization = nil
        self.state = .uncapped
        self.display = Freshness.mark(Format.measure(first), stale: isStale)
        self.windowLabel = first.label
        self.resetsAt = snapshot.metrics.compactMap(\.resetsAt).min()
    }
}
