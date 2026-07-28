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
            [.keychain, .caches, .wallpaperState, .logs, .ownedFiles, .agents])
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
            plan.steps, [.ownedFiles],
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
        let files = FakeFiles(present: [
            "/Users/example/Library/LaunchAgents/com.claudruple.wallpaper.plist"
        ])
        files.contents["/Users/example/Library/LaunchAgents/com.claudruple.wallpaper.plist"] =
            Data(Self.wallpaperPlist.utf8)
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
            "/Users/example/Library/LaunchAgents/com.claudruple.wallpaper.plist",
            "/Users/example/.local/bin/tmud",
        ])
        files.contents["/Users/example/Library/LaunchAgents/com.claudruple.wallpaper.plist"] =
            Data(Self.wallpaperPlist.utf8)
        let launchctl = FakeLaunchctl()
        _ = runner(files: files, launchctl: launchctl).run(MigrationPlan(steps: [.agents]))

        XCTAssertEqual(
            launchctl.calls,
            [
                "bootout com.claudruple.wallpaper",
                "bootstrap com.trackmyusage.wallpaper.plist",
                "enable com.trackmyusage.wallpaper",
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

    // MARK: - Wallpaper state

    /// `WallpaperOrigin` refuses to composite onto anything in the *current* output
    /// directory. A pristine recorded before that guard points into the old one, which the
    /// new guard does not recognise as ours — so the daemon composites the overlay onto a
    /// previous overlay, darkening a little every five minutes, reporting nothing.
    func testASelfReferentialWallpaperIsForgotten() throws {
        let state = "/Users/example/Library/Caches/TrackMyUsage/wallpaper/state.json"
        let files = FakeFiles(present: [state])
        files.contents[state] = Data(
            """
            {"displays":{
              "screen-1":{"lastOutput":"a.png",
                          "pristine":"file:///Users/example/Library/Caches/Claudruple/wallpaper/desktop-a.png"},
              "screen-2":{"lastOutput":"b.png",
                          "pristine":"file:///System/Library/CoreServices/DefaultDesktop.heic"}
            }}
            """.utf8)

        let receipt = runner(files: files).run(MigrationPlan(steps: [.wallpaperState]))
        XCTAssertEqual(receipt.outcome(for: .wallpaperState), .done)

        let written = try XCTUnwrap(files.contents[state])
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: written) as? [String: Any])
        let displays = try XCTUnwrap(root["displays"] as? [String: Any])
        let one = try XCTUnwrap(displays["screen-1"] as? [String: Any])
        let two = try XCTUnwrap(displays["screen-2"] as? [String: Any])

        XCTAssertNil(one["pristine"], "Our own render must not be remembered as the original.")
        XCTAssertNotNil(two["pristine"], "A real wallpaper must survive untouched.")
    }

    func testAWallpaperStateInAnUnexpectedShapeIsLeftAlone() {
        let state = "/Users/example/Library/Caches/TrackMyUsage/wallpaper/state.json"
        let files = FakeFiles(present: [state])
        files.contents[state] = Data("not json".utf8)

        let receipt = runner(files: files).run(MigrationPlan(steps: [.wallpaperState]))
        // Skipped rather than failed: an unreadable state file is not a migration problem,
        // and WallpaperState.load already treats corruption as empty.
        XCTAssertFalse(receipt.outcome(for: .wallpaperState)?.isFailure ?? true)
    }

    // MARK: - Helpers

    private func runner(files: FakeFiles, launchctl: FakeLaunchctl = FakeLaunchctl())
        -> MigrationRunner
    {
        MigrationRunner(
            home: home, files: files, keychain: FakeKeychain(), launchctl: launchctl,
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

struct FakeKeychain: KeychainRelabeling {
    var count = 0
    func relabel(from oldService: String, to newService: String) throws -> Int { count }
}
