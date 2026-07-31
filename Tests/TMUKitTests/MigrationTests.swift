import XCTest

@testable import TMUKit

/// Migration is the one piece of this project that runs exactly once on a machine that
/// already has something valuable on it, and never gets a second chance. So the states that
/// matter — half-migrated, both locations present, a launchctl that refuses, a keychain that
/// is locked — are staged here rather than discovered in the field.
final class MigrationPlanTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/example")

    private func env(
        present: [String] = [],
        legacyKeychain: Bool = false
    ) -> MigrationEnvironment {
        let paths = Set(present.map { home.appendingPathComponent($0).path })
        return MigrationEnvironment(
            home: home,
            exists: { paths.contains($0.path) },
            hasLegacyKeychainItems: { legacyKeychain })
    }

    func testAFreshInstallHasNothingToMigrate() {
        XCTAssertTrue(
            MigrationPlan.probe(env()).isEmpty,
            "A machine that never ran the old version must not be asked to migrate.")
    }

    func testAFullLegacyInstallMigratesEverything() {
        let plan = MigrationPlan.probe(
            env(
                present: [
                    "Library/Caches/Claudruple",
                    "Library/Caches/Claudruple/wallpaper/state.json",
                    "Library/Logs/Claudruple",
                    "Library/Application Support/Claudruple/original-wallpaper.txt",
                    "Library/LaunchAgents/com.claudruple.link.plist",
                    "Library/LaunchAgents/com.claudruple.wallpaper.plist",
                ], legacyKeychain: true))

        XCTAssertEqual(
            plan.steps,
            [.keychain, .caches, .logs, .ownedFiles, .agents, .wallpaperTeardown])
    }

    /// Logs must move before the agents are re-bootstrapped: the new plists name log paths
    /// that launchd expects to be able to open, and a missing directory makes the agent fail
    /// on every launch rather than once.
    func testLogsAreOrderedBeforeAgents() {
        let plan = MigrationPlan.probe(
            env(present: [
                "Library/Logs/Claudruple",
                "Library/LaunchAgents/com.claudruple.link.plist",
            ]))
        let logs = try? XCTUnwrap(plan.steps.firstIndex(of: .logs))
        let agents = try? XCTUnwrap(plan.steps.firstIndex(of: .agents))
        XCTAssertLessThan(logs ?? .max, agents ?? .min)
    }

    func testAHalfMigratedInstallPlansOnlyTheRemainder() {
        // Caches already moved on a previous run; logs did not.
        let plan = MigrationPlan.probe(
            env(present: [
                "Library/Caches/Claudruple",
                "Library/Caches/TrackMyUsage",
                "Library/Logs/Claudruple",
            ]))
        XCTAssertEqual(plan.steps, [.logs], "An already-moved directory must not move twice.")
    }

    /// The guard. Migrating the instance profile root signs every account out — the path is
    /// compiled into each clone's launcher shim, so moving the data does not move what reads
    /// it. No step may ever name that directory as something to move.
    func testMigrationNeverMovesTheInstanceProfileRoot() {
        let plan = MigrationPlan.probe(
            env(present: [
                "Library/Application Support/Claudruple",
                "Library/Application Support/Claudruple/Claude Two",
                "Library/Application Support/Claudruple/original-wallpaper.txt",
            ]))
        XCTAssertFalse(
            plan.touchesInstanceProfiles(home: home),
            """
            A step proposed moving the instance profile directory. That directory is frozen: \
            create-instance.sh compiles its path into every clone's launcher shim, so moving \
            it signs each account out with every extension gone, silently.
            """)
        XCTAssertEqual(
            plan.steps, [.ownedFiles, .wallpaperTeardown],
            "Only the named files we own may be taken out of that directory.")
    }

    func testAProfileDirectoryIsNeverMistakenForAnOwnedFile() {
        XCTAssertFalse(
            LegacyPaths.ownedFilesInInstanceSupport.contains("Claude Two"),
            "The allowlist must name files, never instance profiles.")
    }
}

// MARK: - Runner

final class MigrationRunnerTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/example")

    func testMovingIsSkippedWhenBothLocationsExist() {
        let files = FakeFiles(present: [
            "/Users/example/Library/Logs/Claudruple",
            "/Users/example/Library/Logs/TrackMyUsage",
        ])
        let receipt = runner(files: files).run(MigrationPlan(steps: [.logs]))

        XCTAssertEqual(files.moves.count, 0, "Merging two histories is not migration.")
        guard case .skipped(let why) = try? XCTUnwrap(receipt.outcome(for: .logs)) else {
            return XCTFail(
                "expected a skip, got \(String(describing: receipt.outcome(for: .logs)))")
        }
        XCTAssertTrue(why.contains("both locations"))
    }

    /// A failure in one step must not prevent the others, and must not mark the receipt
    /// complete — otherwise the next launch skips the very thing that did not happen.
    func testAFailedStepIsRecordedAndTheReceiptStaysIncomplete() {
        let files = FakeFiles(present: ["/Users/example/Library/Logs/Claudruple"])
        files.failMoves = true
        let receipt = runner(files: files).run(MigrationPlan(steps: [.logs]))

        XCTAssertTrue(receipt.outcome(for: .logs)?.isFailure ?? false)
        XCTAssertFalse(
            receipt.isComplete,
            "A receipt that says 'complete' after a failure makes the retry never happen.")
    }

    func testRunningTwiceIsANoOpTheSecondTime() {
        let files = FakeFiles(present: ["/Users/example/Library/Logs/Claudruple"])
        let plan = MigrationPlan(steps: [.logs])
        _ = runner(files: files).run(plan)
        XCTAssertEqual(files.moves.count, 1)

        _ = runner(files: files).run(plan)
        XCTAssertEqual(files.moves.count, 1, "The old location is gone; there is nothing to move.")
    }

    /// The agent's plist names a binary by absolute path. Until the user rebuilds, that
    /// binary does not exist under its new name, and rewriting the plist would replace a
    /// working agent with one that fails on every launch.
    func testAgentsWaitForTheBinaryToExist() {
        // The link agent, because the wallpaper agent is no longer renamed — it is removed
        // by .wallpaperTeardown, and renaming one on its way out would bootstrap a fresh
        // copy pointing at a binary this release deleted.
        let files = FakeFiles(present: [
            "/Users/example/Library/LaunchAgents/com.claudruple.link.plist"
        ])
        files.contents["/Users/example/Library/LaunchAgents/com.claudruple.link.plist"] =
            Data(Self.linkPlist.utf8)
        let launchctl = FakeLaunchctl()
        let receipt = runner(files: files, launchctl: launchctl).run(
            MigrationPlan(steps: [.agents]))

        XCTAssertTrue(launchctl.calls.isEmpty, "Nothing should be booted out yet.")
        guard case .skipped(let why) = try? XCTUnwrap(receipt.outcome(for: .agents)) else {
            return XCTFail("expected a skip")
        }
        XCTAssertTrue(why.contains("does not exist yet"), why)
    }

    func testAgentsAreBootedOutBeforeTheNewOneIsBootstrapped() {
        let files = FakeFiles(present: [
            "/Users/example/Library/LaunchAgents/com.claudruple.link.plist",
            "/Applications/Claudruple/TrackMyUsage Link.app/Contents/MacOS/TrackMyUsage Link",
        ])
        files.contents["/Users/example/Library/LaunchAgents/com.claudruple.link.plist"] =
            Data(Self.linkPlist.utf8)
        let launchctl = FakeLaunchctl()
        _ = runner(files: files, launchctl: launchctl).run(MigrationPlan(steps: [.agents]))

        XCTAssertEqual(
            launchctl.calls,
            [
                "bootout com.claudruple.link",
                "bootstrap com.trackmyusage.link.plist",
                "enable com.trackmyusage.link",
            ],
            """
            Bootstrapping before booting out leaves two wallpaper agents racing for the \
            desktop, or two brokers fighting over claude://.
            """)
    }

    // MARK: - Plist rewriting

    func testRewritingAPlistLeavesTheFrozenInstallDirectoryAlone() {
        let rewritten = MigrationRunner.rewrite(Self.linkPlist)

        XCTAssertTrue(
            rewritten.contains("/Applications/Claudruple/TrackMyUsage Link.app"),
            """
            The directory is frozen — clones are registered there — but the broker bundle \
            inside it is renamed. One string, two different rules.
            """)
        XCTAssertTrue(rewritten.contains("com.trackmyusage.link"))
        XCTAssertTrue(rewritten.contains("Library/Logs/TrackMyUsage"))
        XCTAssertFalse(rewritten.contains("com.claudruple.link"))
    }

    func testTheProgramPathIsReadFromTheRewrittenPlist() {
        XCTAssertEqual(
            MigrationRunner.firstProgramArgument(in: MigrationRunner.rewrite(Self.wallpaperPlist)),
            "/Users/example/.local/bin/tmud")
    }

    // MARK: - Wallpaper teardown

    /// The whole reason this step exists. An install that ran the wallpaper agent has a
    /// LaunchAgent on a 300s timer invoking a `tmud` that this release deleted, and a rendered
    /// PNG set as its desktop. Removing the feature without removing its footprint leaves a
    /// timer failing silently forever and a background macOS keeps no history of.
    func testTeardownStopsTheAgentRestoresTheDesktopAndDeletesTheRenders() throws {
        let record = "Library/Application Support/TrackMyUsage/original-wallpaper.txt"
        let original = "/Users/example/Pictures/mountain.heic"
        let files = FakeFiles(
            present: abs(
                "Library/LaunchAgents/com.trackmyusage.wallpaper.plist", record,
                "Library/Caches/TrackMyUsage/wallpaper") + [original])
        files.contents[home.appendingPathComponent(record).path] = Data(original.utf8)

        let launchctl = FakeLaunchctl()
        let desktop = FakeDesktop()
        let receipt = runner(files: files, launchctl: launchctl, desktop: desktop)
            .run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertEqual(receipt.outcome(for: .wallpaperTeardown), .done)
        XCTAssertTrue(launchctl.calls.contains("bootout com.trackmyusage.wallpaper"))
        XCTAssertEqual(desktop.set.map(\.path), [original])
        XCTAssertFalse(
            files.exists(home.appendingPathComponent("Library/Caches/TrackMyUsage/wallpaper")))
    }

    /// Both labels, because an install may have been renamed before the feature was dropped
    /// or may still be on the old one. Missing either leaves a live timer behind.
    func testTeardownStopsBothTheOldAndNewAgentLabels() {
        let files = FakeFiles(
            present: abs(
                "Library/LaunchAgents/com.claudruple.wallpaper.plist",
                "Library/LaunchAgents/com.trackmyusage.wallpaper.plist"))
        let launchctl = FakeLaunchctl()
        _ = runner(files: files, launchctl: launchctl)
            .run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertTrue(launchctl.calls.contains("bootout com.claudruple.wallpaper"))
        XCTAssertTrue(launchctl.calls.contains("bootout com.trackmyusage.wallpaper"))
    }

    /// Order is load-bearing: restoring reads the recorded path, and deleting the renders
    /// first would remove the file being restored from in the case where someone's chosen
    /// wallpaper had itself been stored under our cache directory.
    func testTeardownRestoresBeforeDeletingTheRenders() throws {
        let record = "Library/Application Support/TrackMyUsage/original-wallpaper.txt"
        let original = "/Users/example/Pictures/leaf.jpg"
        let files = FakeFiles(
            present: abs(record, "Library/Caches/TrackMyUsage/wallpaper") + [original])
        files.contents[home.appendingPathComponent(record).path] = Data(original.utf8)

        let desktop = FakeDesktop()
        _ = runner(files: files, desktop: desktop).run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertEqual(desktop.set.count, 1, "the desktop must be restored")
        XCTAssertFalse(
            files.exists(home.appendingPathComponent("Library/Caches/TrackMyUsage/wallpaper")))
    }

    /// A person who deleted their old wallpaper is not a migration that went wrong. Failing
    /// here would leave the receipt incomplete and re-run every other step on every launch.
    func testARecordedOriginalThatNoLongerExistsIsReportedRatherThanFailing() {
        let record = "Library/Application Support/TrackMyUsage/original-wallpaper.txt"
        let files = FakeFiles(present: abs(record))
        files.contents[home.appendingPathComponent(record).path] =
            Data("/Users/example/Pictures/deleted.jpg".utf8)

        let desktop = FakeDesktop()
        let receipt = runner(files: files, desktop: desktop)
            .run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertFalse(receipt.outcome(for: .wallpaperTeardown)?.isFailure ?? true)
        XCTAssertTrue(desktop.set.isEmpty, "nothing to restore, so nothing is set")
    }

    /// The record is checked in both support directories because `.ownedFiles` moves it, and
    /// teardown has to work whether or not that step has already run.
    func testTheRecordIsFoundInThePreRenameSupportDirectoryToo() {
        let record = "Library/Application Support/Claudruple/original-wallpaper.txt"
        let original = "/Users/example/Pictures/old.jpg"
        let files = FakeFiles(present: abs(record) + [original])
        files.contents[home.appendingPathComponent(record).path] = Data(original.utf8)

        let desktop = FakeDesktop()
        _ = runner(files: files, desktop: desktop).run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertEqual(desktop.set.map(\.path), [original])
    }

    /// Idempotent: a second run on a clean machine must skip, not fail. The receipt only marks
    /// complete when every step is non-failing, so a step that failed on nothing would re-run
    /// the whole migration on every launch forever.
    func testTeardownOnAMachineWithNoWallpaperInstallSkips() {
        let receipt = runner(files: FakeFiles(present: []))
            .run(MigrationPlan(steps: [.wallpaperTeardown]))

        XCTAssertEqual(
            receipt.outcome(for: .wallpaperTeardown), .skipped("no wallpaper install to remove"))
    }

    /// The wallpaper agent must not be in the rename list. Renaming it would bootstrap a fresh
    /// copy on a 300s timer pointing at a deleted binary — the removal causing exactly the
    /// damage it exists to prevent.
    func testTheWallpaperAgentIsNotRenamedAlongsideTheBroker() {
        XCTAssertFalse(
            LegacyPaths.agents.contains { $0.oldLabel.contains("wallpaper") },
            "the wallpaper agent is removed, not renamed")
    }

    // MARK: - Helpers

    /// FakeFiles keys on absolute paths; the fixtures below are written home-relative.
    private func abs(_ relative: String...) -> [String] {
        relative.map { home.appendingPathComponent($0).path }
    }

    private func runner(
        files: FakeFiles,
        launchctl: FakeLaunchctl = FakeLaunchctl(),
        desktop: FakeDesktop = FakeDesktop()
    ) -> MigrationRunner {
        MigrationRunner(
            home: home, files: files, keychain: FakeKeychain(), launchctl: launchctl,
            desktop: desktop,
            legacyKeychainService: "com.claudruple.usage",
            newKeychainService: "com.trackmyusage.usage")
    }

    private static let linkPlist = """
        <plist version="1.0"><dict>
        <key>Label</key><string>com.claudruple.link</string>
        <key>ProgramArguments</key>
        <array><string>/Applications/Claudruple/Claudruple Link.app/Contents/MacOS/Claudruple Link</string></array>
        <key>StandardErrorPath</key><string>/Users/example/Library/Logs/Claudruple/link.stderr.log</string>
        </dict></plist>
        """

    private static let wallpaperPlist = """
        <plist version="1.0"><dict>
        <key>Label</key><string>com.claudruple.wallpaper</string>
        <key>ProgramArguments</key>
        <array><string>/Users/example/.local/bin/claudrupled</string><string>apply</string></array>
        <key>StartInterval</key><integer>300</integer>
        </dict></plist>
        """
}

// MARK: - Fakes

final class FakeFiles: FileMoving, @unchecked Sendable {
    private(set) var present: Set<String>
    var contents: [String: Data] = [:]
    private(set) var moves: [(from: String, to: String)] = []
    var failMoves = false

    init(present: [String] = []) { self.present = Set(present) }

    func exists(_ url: URL) -> Bool { present.contains(url.path) }

    func move(_ from: URL, to: URL) throws {
        if failMoves { throw MigrationError.keychain(-1) }
        moves.append((from.path, to.path))
        present.remove(from.path)
        present.insert(to.path)
        if let data = contents.removeValue(forKey: from.path) { contents[to.path] = data }
    }

    func read(_ url: URL) throws -> Data {
        guard let data = contents[url.path] else { throw MigrationError.keychain(-2) }
        return data
    }

    func write(_ data: Data, to url: URL) throws {
        contents[url.path] = data
        present.insert(url.path)
    }

    func remove(_ url: URL) throws {
        present.remove(url.path)
        contents.removeValue(forKey: url.path)
    }

    func createDirectory(_ url: URL) throws { present.insert(url.path) }
}

final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    private(set) var calls: [String] = []
    func bootout(label: String) throws { calls.append("bootout \(label)") }
    func bootstrap(plist: URL) throws { calls.append("bootstrap \(plist.lastPathComponent)") }
    func enable(label: String) throws { calls.append("enable \(label)") }
}

final class FakeDesktop: DesktopRestoring, @unchecked Sendable {
    private(set) var set: [URL] = []
    func setDesktopImage(_ url: URL) throws { set.append(url) }
}

struct FakeKeychain: KeychainRelabeling {
    var count = 0
    func relabel(from oldService: String, to newService: String) throws -> Int { count }
}
