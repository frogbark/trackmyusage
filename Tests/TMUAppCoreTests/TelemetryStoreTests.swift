import TMUDesign
import TMUKit
import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMUAppCore

/// The app's first tests. They exist because the executable target was split into a library;
/// none of this was reachable before, which is why none of it was covered.
@MainActor
final class TelemetryStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Fakes

    private struct StubInstances: InstanceReading {
        var snapshots: [UsageSnapshot] = []
        func read(now: Date) -> InstanceReadingResult {
            InstanceReadingResult(
                snapshots: snapshots, rows: [], advice: nil, activeInstance: nil, alerts: [])
        }
    }

    private struct StubProviders: ProviderReadingSource {
        var snapshots: [UsageSnapshot] = []
        var delay: Duration = .zero
        func collect(now: Date, excluding hidden: Set<String>) async -> [UsageSnapshot] {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return snapshots.filter { !hidden.contains($0.provider) }
        }
    }

    /// Defaults to the real clock, not the fixed one.
    ///
    /// The store builds its model against `Date()`, so a fixture stamped in 2026 is half a
    /// year stale and every display carries a `?`. Tests that want staleness ask for it.
    private func snapshot(
        _ provider: String, _ value: Double, account: String? = nil, observedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: account, observedAt: observedAt ?? Date(), status: .ok,
            metrics: [
                Metric(
                    key: "usage", kind: .percentOfLimit, value: value, limit: nil,
                    window: .rolling(3600), resetsAt: nil)
            ])
    }

    private func store(
        instances: [UsageSnapshot] = [], providers: [UsageSnapshot] = [],
        settings: Settings = Settings(), cache: SnapshotCache? = nil
    ) -> TelemetryStore {
        TelemetryStore(
            instanceSource: StubInstances(snapshots: instances),
            providerSource: StubProviders(snapshots: providers),
            cache: cache ?? temporaryCache(),
            settings: settings,
            startTimers: false)
    }

    private func temporaryCache() -> SnapshotCache {
        SnapshotCache(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tmu-test-\(UUID().uuidString).json"))
    }

    // MARK: - The gap this closes

    /// The whole reason for the restructure: the app could not see a provider at all, because
    /// TMUApp depended on TMUKit alone. Every SERVICES section in the design needed this.
    func testTheStoreSeesBothAccountsAndProviders() async {
        let subject = store(
            instances: [snapshot("claude", 62, account: "Claude")],
            providers: [snapshot("github", 41)])
        await settle()

        XCTAssertEqual(subject.model.claude.map(\.name), ["Claude"])
        XCTAssertEqual(subject.model.services.map(\.name), ["github"])
    }

    /// The same value the wallpaper renders, so the two surfaces cannot disagree.
    func testAccountsAndServicesShareOneInterpretation() async {
        let subject = store(
            instances: [snapshot("claude", 96, account: "Claude Two")],
            providers: [snapshot("github", 41)])
        await settle()

        XCTAssertEqual(subject.model.claude.first?.state, .warn)
        XCTAssertEqual(subject.model.claude.first?.display, "96%")
        XCTAssertEqual(subject.model.attention, .alert)
    }

    // MARK: - Cache

    /// Opening the menu bar to a blank panel while a round-trip completes reads as broken.
    func testThePopoverHasContentBeforeTheFirstFetchLands() {
        let cache = temporaryCache()
        try? cache.save([snapshot("github", 41)])

        let subject = store(providers: [], cache: cache)
        XCTAssertEqual(
            subject.model.services.map(\.name), ["github"],
            "the last good readings should be on screen synchronously at init")
    }

    /// And they must not be presented as current. Each cached snapshot carries its real
    /// observedAt, so the staleness rule marks it the moment it is drawn.
    func testRestoredReadingsAreMarkedStaleRatherThanPresentedAsCurrent() {
        let cache = temporaryCache()
        try? cache.save([
            snapshot("github", 41, observedAt: Date().addingTimeInterval(-3600))
        ])

        let subject = store(providers: [], cache: cache)
        XCTAssertTrue(subject.model.services.first?.isStale ?? false)
        XCTAssertEqual(subject.model.services.first?.display, "41%?")
    }

    func testACorruptCacheIsSimplyEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-test-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(SnapshotCache(url: url).load().count, 0)
    }

    // MARK: - Settings

    func testHiddenProvidersAreNotCollected() async {
        var settings = Settings()
        settings.hiddenProviders = ["github"]
        let subject = store(
            providers: [snapshot("github", 41), snapshot("stripe", 10)], settings: settings)
        await settle()

        XCTAssertEqual(subject.model.services.map(\.name), ["stripe"])
    }

    /// `notificationsEnabled` used to live in memory and reset on every launch.
    func testSettingsPersistOnChange() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var settings = Settings()
        settings.notificationsEnabled = false
        try SettingsStore.save(settings, to: url)

        XCTAssertFalse(SettingsStore.load(from: url).notificationsEnabled)
    }

    /// A newer app writing a layout an older daemon has never heard of must not brick it.
    func testAnUnknownLayoutFallsBackRatherThanFailingTheWholeFile() {
        var settings = Settings()
        settings.layoutByDisplay = ["screen-1": "hologram"]
        settings.defaultLayout = "card"

        XCTAssertEqual(
            settings.layout(for: "screen-1", known: ["ledger", "board", "card"]), "card")
        XCTAssertEqual(
            settings.layout(for: "screen-2", known: ["ledger", "board", "card"]), "card")
    }

    func testAPerDisplayChoiceBeatsTheDefault() {
        var settings = Settings()
        settings.defaultLayout = "ledger"
        settings.layoutByDisplay = ["screen-1": "board"]
        XCTAssertEqual(
            settings.layout(for: "screen-1", known: ["ledger", "board", "card"]), "board")
    }

    // MARK: - Concurrency

    /// A manual Refresh during a slow poll must not produce two writes whose order is luck.
    func testASlowFetchIsCancelledByANewerOne() async {
        let subject = TelemetryStore(
            instanceSource: StubInstances(),
            providerSource: StubProviders(
                snapshots: [snapshot("slow", 10)], delay: .milliseconds(400)),
            cache: temporaryCache(), settings: Settings(), startTimers: false)

        subject.refreshProviders()
        subject.refreshProviders()
        await settle(for: .milliseconds(600))

        XCTAssertEqual(
            subject.model.services.count, 1,
            "the cancelled fetch must not also have applied its result")
    }

    /// One provider that never answers must not hold the whole refresh open.
    func testAPathologicalProviderDoesNotPinTheRefresh() async {
        let result = await withTimeout(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(30))
            return "finished"
        }
        XCTAssertNil(result, "the budget has to actually bound the wait")
    }

    // MARK: -

    private func settle(for duration: Duration = .milliseconds(120)) async {
        try? await Task.sleep(for: duration)
    }
}
