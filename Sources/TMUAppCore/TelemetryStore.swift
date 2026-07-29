import Foundation
import TMUClaude
import TMUDesign
import TMUKit
import TMUProviders
import TMUTelemetry

/// Everything the app draws, kept current.
///
/// Replaces `UsageStore`, which conflated discovery, polling, alerting and view-model
/// shaping in one synchronous body and — the reason this had to change — could only see
/// Claude's local files. `TMUApp` depended on `TMUKit` alone, so the menu bar structurally
/// could not show a provider. Every SERVICES section in the new design needed this first.
///
/// Two cadences, deliberately different:
///
///   instances  30s   local file reads, cheap. Claude rewrites plan-usage-history.json
///                    roughly every five minutes, so 30s is already generous.
///   providers  300s  network. Polling seventeen rate-limited APIs every thirty seconds
///                    would be rude to them and useless to us; nothing moves that fast.
@MainActor
public final class TelemetryStore: ObservableObject {

    /// One Claude instance, with the instance-management details the wallpaper does not need.
    public struct InstanceRow: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let bundleID: String
        public let isPrimary: Bool
        public let extensionCount: Int
        public let metrics: [(label: String, value: Double, state: UsageState)]
    }

    @Published public private(set) var model: TelemetryModel
    @Published public private(set) var instances: [InstanceRow] = []
    @Published public private(set) var advice: SteeringAdvice?
    @Published public private(set) var activeInstance: String?
    @Published public var settings: Settings {
        didSet { try? SettingsStore.save(settings) }
    }

    /// Set when migration left a step undone. Surfaced once in the UI rather than swallowed:
    /// being honestly incomplete beats being quietly wrong.
    @Published public private(set) var migrationNotice: String?
    /// Clones on a different build from the installed Claude Desktop.
    ///
    /// Surfaced in the popover because the failure mode is silence: a clone several versions
    /// behind launches, signs in and works, and nothing anywhere says otherwise until
    /// something server-side stops accommodating it.
    @Published public private(set) var staleInstances: [String] = []

    private let instanceSource: any InstanceReading
    private let providerSource: any ProviderReadingSource
    private let cache: SnapshotCache
    private var alerts = AlertPolicy()
    private var providerSnapshots: [UsageSnapshot] = []
    private var instanceSnapshots: [UsageSnapshot] = []
    private var providerTask: Task<Void, Never>?
    private var timers: [Timer] = []

    public static let instancePollInterval: TimeInterval = 30

    public init(
        instanceSource: any InstanceReading = LocalInstances(),
        providerSource: any ProviderReadingSource = NetworkProviders(),
        cache: SnapshotCache = SnapshotCache(),
        settings: Settings = SettingsStore.load(),
        startTimers: Bool = true
    ) {
        self.instanceSource = instanceSource
        self.providerSource = providerSource
        self.cache = cache
        self.settings = settings

        // Load the last good readings synchronously so the popover has content the instant
        // it opens. Each snapshot carries its real observedAt, so anything over half an hour
        // old is marked `?` immediately — instant, honest, and self-correcting once the
        // first fetch lands.
        self.providerSnapshots = cache.load()
        self.model = TelemetryModel.build(snapshots: providerSnapshots, now: Date())

        refreshInstances()
        refreshProviders()

        guard startTimers else { return }
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.instancePollInterval, repeats: true) {
                _ in Task { @MainActor [weak self] in self?.refreshInstances() }
            },
            Timer.scheduledTimer(withTimeInterval: settings.providerPollInterval, repeats: true) {
                _ in Task { @MainActor [weak self] in self?.refreshProviders() }
            },
        ]
    }

    deinit { timers.forEach { $0.invalidate() } }

    public func note(migration: String?) { migrationNotice = migration }

    public func dismissMigrationNotice() { migrationNotice = nil }

    // MARK: - Refreshing

    public func refreshInstances() {
        let reading = instanceSource.read(now: Date())
        instanceSnapshots = reading.snapshots
        instances = reading.rows
        staleInstances = reading.staleInstances
        advice = reading.advice
        activeInstance = reading.activeInstance
        rebuild()
        notifyIfNeeded(reading)
    }

    public func refreshProviders() {
        // Cancel any in-flight fetch. A manual Refresh during a slow poll would otherwise
        // produce two writes, and the older one could land last.
        providerTask?.cancel()
        let source = providerSource
        let hidden = settings.hiddenProviders
        providerTask = Task { [weak self] in
            let snapshots = await source.collect(now: Date(), excluding: hidden)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.apply(snapshots) }
        }
    }

    private func apply(_ snapshots: [UsageSnapshot]) {
        providerSnapshots = snapshots
        try? cache.save(snapshots)
        rebuild()
    }

    private func rebuild() {
        model = TelemetryModel.build(
            snapshots: instanceSnapshots + providerSnapshots, now: Date())
    }

    // MARK: - Notifications

    private func notifyIfNeeded(_ reading: InstanceReadingResult) {
        guard settings.notificationsEnabled else { return }
        for alert in reading.alerts
        where alerts.shouldNotify(
            account: alert.account, metric: alert.metric, value: alert.value)
        {
            Notifier.post(alert)
        }
    }
}
