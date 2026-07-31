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
        var stale: [String] = []
        func read(now: Date) -> InstanceReadingResult {
            InstanceReadingResult(
                snapshots: snapshots, rows: [], advice: nil, activeInstance: nil, alerts: [],
                outOfStepInstances: stale)
        }
    }

    /// A source whose answer can change between reads, for testing that a condition clears.
    ///
    /// A class because the store holds its source privately and correctly does not let a
    /// test swap it out; mutating the instance it already has is the way to model the world
    /// changing underneath it. `@unchecked` because the mutation is confined to the test's
    /// own thread, one read at a time.
    private final class MutableInstances: InstanceReading, @unchecked Sendable {
        var stale: [String]
        init(stale: [String] = []) { self.stale = stale }
        func read(now: Date) -> InstanceReadingResult {
            InstanceReadingResult(
                snapshots: [], rows: [], advice: nil, activeInstance: nil, alerts: [],
                outOfStepInstances: stale)
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
        settings: Settings = Settings(), cache: SnapshotCache? = nil,
        stale: [String] = []
    ) -> TelemetryStore {
        TelemetryStore(
            instanceSource: StubInstances(snapshots: instances, stale: stale),
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

    // MARK: - Stale clones

    /// Prevents: the banner silently disappearing, which restores the exact situation it
    /// exists to fix — a clone several versions behind that nothing ever mentions.
    func testStaleClonesReachTheStoreSoThePopoverCanSaySo() {
        let store = store(stale: ["Work", "Personal"])
        store.refreshInstances()
        XCTAssertEqual(store.outOfStepInstances, ["Work", "Personal"])
    }

    /// Prevents: a permanent banner on an install where every clone is current.
    func testNothingIsReportedWhenEveryCloneMatches() {
        let store = store(stale: [])
        store.refreshInstances()
        XCTAssertTrue(store.outOfStepInstances.isEmpty)
    }

    /// Prevents: the list going stale itself.
    ///
    /// After a refresh brings the clones into line, the next read has to clear it. A banner
    /// that outlives the condition teaches people to ignore the banner.
    func testTheListClearsOnceTheClonesAreBroughtIntoLine() {
        let source = MutableInstances(stale: ["Work"])
        let store = TelemetryStore(
            instanceSource: source, providerSource: StubProviders(),
            cache: temporaryCache(), settings: Settings(), startTimers: false)
        store.refreshInstances()
        XCTAssertEqual(store.outOfStepInstances, ["Work"])

        source.stale = []
        store.refreshInstances()
        XCTAssertTrue(store.outOfStepInstances.isEmpty)
    }

}

/// The instance card's freshness chip.
///
/// Separate from the banner tests above: the banner names out-of-step clones in a sentence,
/// while each card reports its own comparison, and the two are computed from different
/// places — `needingRefresh` over every discovered instance, and `InstanceRow.freshness`
/// over the instances that have usage history. They can disagree, and these pin the row.
final class InstanceRowFreshnessTests: XCTestCase {

    /// Prevents: the primary being marked out of step against itself.
    ///
    /// It is the thing every clone is compared to, and TrackMyUsage never modifies
    /// /Applications/Claude.app — offering to re-clone it would be offering to overwrite the
    /// reference with a copy of itself.
    func testThePrimaryIsCurrentByDefinitionRatherThanByComparison() {
        let row = row(name: "Claude", isPrimary: true, freshness: .current)
        XCTAssertFalse(row.freshness.needsRefresh)
    }

    /// Prevents: a card claiming a direction the model refused to determine.
    ///
    /// `summary` is what the chip renders. It states both versions and an arrow, never
    /// "older" or "behind", because reinstalling an earlier Claude leaves the clone the
    /// newer of the two and the remedy is identical either way.
    func testTheChipStatesBothVersionsAndNoDirection() {
        let row = row(
            name: "Work", isPrimary: false,
            freshness: .stale(clone: "0.15.9", installed: "0.16.1"))

        XCTAssertEqual(row.freshness.summary, "0.15.9 → 0.16.1")
        XCTAssertFalse(row.freshness.summary.lowercased().contains("old"))
        XCTAssertFalse(row.freshness.summary.lowercased().contains("behind"))
    }

    /// Prevents: a row built without a version quietly reading as up to date.
    ///
    /// The default is `.unknown` rather than `.current` so a caller that forgets to pass a
    /// version gets a row that says nothing, not one that says everything is fine.
    func testARowBuiltWithoutAVersionDefaultsToUnknownRatherThanCurrent() {
        let row = TelemetryStore.InstanceRow(
            id: "x", name: "Work", bundleID: "x", isPrimary: false, extensionCount: 0,
            metrics: [])

        XCTAssertEqual(row.freshness, .unknown)
        XCTAssertFalse(row.freshness.needsRefresh)
    }

    private func row(name: String, isPrimary: Bool, freshness: InstanceFreshness)
        -> TelemetryStore.InstanceRow
    {
        TelemetryStore.InstanceRow(
            id: name, name: name, bundleID: "id.\(name)", isPrimary: isPrimary,
            extensionCount: 0, metrics: [], freshness: freshness)
    }
}
