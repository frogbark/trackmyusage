import Foundation
import TMUClaude
import TMUDesign
import TMUKit
import TMUProviders
import TMUTelemetry

// The two things the store reads from, behind protocols so it can be tested without a
// machine that has Claude Desktop installed or a network that answers.

/// One round of reading local instances.
public struct InstanceReadingResult: Sendable {
    public let snapshots: [UsageSnapshot]
    public let rows: [TelemetryStore.InstanceRow]
    public let advice: SteeringAdvice?
    public let activeInstance: String?
    public let alerts: [Alert]
    /// Clones on a different build from the installed Claude Desktop.
    ///
    /// Computed from every discovered instance rather than from `rows`, which only contains
    /// instances that have usage history to show. A clone nobody has signed into yet is
    /// still a clone that will not update itself.
    ///
    /// Named "out of step" rather than "stale" because this view already has a `isStale`,
    /// meaning a *reading* older than thirty minutes. Two unrelated conditions sharing one
    /// word in one file is how someone eventually wires a bundle version into a freshness
    /// colour, or reads this list and thinks the numbers are old.
    public let outOfStepInstances: [String]

    public struct Alert: Sendable {
        public let account: String
        public let metric: UsageMetric
        public let value: Double
        public let recommendation: String?
    }

    public init(
        snapshots: [UsageSnapshot], rows: [TelemetryStore.InstanceRow],
        advice: SteeringAdvice?, activeInstance: String?, alerts: [Alert],
        outOfStepInstances: [String] = []
    ) {
        self.snapshots = snapshots
        self.rows = rows
        self.advice = advice
        self.activeInstance = activeInstance
        self.alerts = alerts
        self.outOfStepInstances = outOfStepInstances
    }
}

public protocol InstanceReading: Sendable {
    func read(now: Date) -> InstanceReadingResult
}

public protocol ProviderReadingSource: Sendable {
    func collect(now: Date, excluding hidden: Set<String>) async -> [UsageSnapshot]
}

// MARK: - Local instances

public struct LocalInstances: InstanceReading {

    /// How instances are found. Injectable so the reading can be tested against fixtures on
    /// disk; production uses the real locator.
    private let discover: @Sendable () -> [DiscoveredInstance]

    public init(
        discover: @escaping @Sendable () -> [DiscoveredInstance] = {
            InstanceLocator.discover()
        }
    ) {
        self.discover = discover
    }

    public func read(now: Date) -> InstanceReadingResult {
        var accounts: [AccountUsage] = []
        var rows: [TelemetryStore.InstanceRow] = []
        var alerts: [InstanceReadingResult.Alert] = []

        let discovered = discover()
        // Read once, outside the loop: it is a property of the machine, not of each clone.
        let installedClaude = discovered.installedClaudeVersion
        for instance in discovered {
            let file = instance.profileURL.appendingPathComponent("plan-usage-history.json")
            // Missing history stops this instance contributing *usage*. It does not stop it
            // existing. The loop used to `continue` here, so an instance created an hour ago
            // and not yet signed into was absent from the window whose subject is instances —
            // and the out-of-step banner, which counts every discovered clone, could name one
            // that had no row to look at.
            let history = (try? UsageHistory.parse(contentsOf: file))
                .flatMap { $0.samples.isEmpty ? nil : $0 }

            // Read the extension count here, once per refresh. It used to be a computed
            // property on the SwiftUI view, which meant a synchronous disk read on every
            // invalidation of that row.
            let extensions =
                (try? ProfileReader.read(
                    name: instance.name, profileURL: instance.profileURL))?
                .extensions.count ?? 0

            var metrics: [(label: String, value: Double, state: UsageState)] = []

            if let history {
                let usage = AccountUsage(
                    instanceName: instance.name, bundleID: instance.bundleID, history: history)
                accounts.append(usage)

                // Only windowed metrics: an unwindowed figure has no cap to be a fraction of,
                // so rendering it as a percentage would invent a limit that does not exist.
                metrics =
                    (history.samples.last?.metrics ?? [:])
                    .filter { $0.key.window != nil }
                    .map {
                        (
                            label: $0.key.displayName, value: $0.value,
                            state: UsageState.classify(utilization: $0.value)
                        )
                    }
                    .sorted { $0.label < $1.label }

                if let binding = usage.binding(now: now) {
                    alerts.append(
                        .init(
                            account: instance.name, metric: binding.metric,
                            value: binding.value, recommendation: nil))
                }
            }

            rows.append(
                TelemetryStore.InstanceRow(
                    id: instance.bundleID, name: instance.name, bundleID: instance.bundleID,
                    isPrimary: instance.isPrimary, extensionCount: extensions,
                    metrics: metrics,
                    // The primary is the reference every clone is measured against, so it is
                    // current by definition rather than by comparison.
                    freshness: instance.isPrimary
                        ? .current
                        : InstanceFreshness.compare(
                            clone: instance.version, installed: installedClaude),
                    hasReadings: history != nil))
        }

        let active = Self.inferActive(accounts, now: now)
        let advice = Steering.advise(accounts: accounts, activeInstance: active, now: now)
        // `.none` urgency means there is nothing worth saying; the banner is hidden rather
        // than shown empty.
        let worthShowing = advice.urgency == .none ? nil : advice

        return InstanceReadingResult(
            // Through ClaudeUsage so the app and the widget see identical values for the
            // same account. Two paths to the same number is how they drift.
            snapshots: accounts.map(ClaudeUsage.snapshot(of:)),
            rows: rows,
            advice: worthShowing,
            activeInstance: active,
            alerts: alerts.map {
                .init(
                    account: $0.account, metric: $0.metric, value: $0.value,
                    recommendation: advice.recommended)
            },
            outOfStepInstances: discovered.needingRefresh.map(\.name))
    }

    /// Which account is being worked in.
    ///
    /// `frontmostApplication` would name whichever window has focus, which is routinely a
    /// browser or an editor. The instance whose 5-hour window is climbing fastest is the one
    /// actually consuming budget.
    static func inferActive(_ accounts: [AccountUsage], now: Date) -> String? {
        accounts
            .compactMap { account -> (String, Double)? in
                guard let forecast = account.history.forecast(for: .fiveHour, now: now),
                    let rate = forecast.pointsPerHourOrNil, rate > 0
                else { return nil }
                return (account.instanceName, rate)
            }
            .max { $0.1 < $1.1 }?.0
    }
}

// MARK: - Network providers

public struct NetworkProviders: ProviderReadingSource {
    public init() {}

    /// Twenty seconds, above URLSession's own fifteen.
    ///
    /// The per-request timeout does not bound a provider that answers slowly in many small
    /// pieces, and the app polls on a timer; one pathological adapter must not be able to
    /// hold a refresh open indefinitely.
    static let budget: Duration = .seconds(20)

    public func collect(now: Date, excluding hidden: Set<String>) async -> [UsageSnapshot] {
        let credentials = KeychainCredentials()
        let providers = ProviderRegistry.all().filter { provider in
            guard !hidden.contains(provider.id) else { return false }
            // Fetching a provider nobody has connected would spend a request to draw
            // "unauthorized" at somebody.
            return !provider.credentialSpec.required
                || ((try? credentials.secret(for: provider.id)) ?? nil) != nil
        }
        guard !providers.isEmpty else { return [] }

        return await withTaskGroup(of: UsageSnapshot?.self) { group in
            for provider in providers {
                group.addTask {
                    await withTimeout(Self.budget) {
                        // `snapshot` never throws: a failure occupies its own row rather
                        // than taking the whole group down.
                        await provider.snapshot(credentials: credentials, now: now)
                    }
                }
            }
            var collected: [UsageSnapshot] = []
            for await snapshot in group {
                if let snapshot { collected.append(snapshot) }
            }
            return collected
        }
    }
}

/// Run `work`, or give up. Returns nil on timeout.
func withTimeout<T: Sendable>(
    _ duration: Duration, _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: duration)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
