import XCTest

@testable import TMUKit

/// The fakes above prove the logic. This proves the logic is wired to a real filesystem —
/// that `SystemFileMover` moves what the plan names, in a directory laid out the way a real
/// install is, including the instance profile that must survive untouched.
final class MigrationIntegrationTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Lay out what this machine actually looked like before the rename.
    private func stageLegacyInstall() throws {
        let fm = FileManager.default
        func write(_ contents: String, to relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        try write("png", to: "Library/Caches/Claudruple/wallpaper/desktop-a.png")
        try write(
            """
            {"displays":{"screen-1":{"lastOutput":"desktop-a.png",
             "pristine":"file://\(home.path)/Library/Caches/Claudruple/wallpaper/desktop-b.png"}}}
            """, to: "Library/Caches/Claudruple/wallpaper/state.json")
        try write("log", to: "Library/Logs/Claudruple/wallpaper.log")
        try write(
            "/System/.../Lake.heic",
            to: "Library/Application Support/Claudruple/original-wallpaper.txt")

        // The thing that must not move: a signed-in instance profile, beside our file.
        try write("{}", to: "Library/Application Support/Claudruple/Claude Two/Preferences")
        try write(
            "sqlite", to: "Library/Application Support/Claudruple/Claude Two/Local Storage/db")
    }

    func testAFullLegacyInstallMigratesAndLeavesTheProfileAlone() throws {
        try stageLegacyInstall()
        let files = SystemFileMover()

        let environment = MigrationEnvironment(
            home: home, exists: { files.exists($0) }, hasLegacyKeychainItems: { false })
        let plan = MigrationPlan.probe(environment)
        XCTAssertEqual(plan.steps, [.caches, .wallpaperState, .logs, .ownedFiles])

        let receipt = MigrationRunner(
            home: home, files: files, keychain: FakeKeychain(), launchctl: FakeLaunchctl(),
            legacyKeychainService: "old", newKeychainService: "new"
        ).run(plan)

        XCTAssertTrue(receipt.isComplete, "\(receipt.outcomes)")

        // Moved.
        XCTAssertTrue(exists("Library/Caches/TrackMyUsage/wallpaper/desktop-a.png"))
        XCTAssertTrue(exists("Library/Logs/TrackMyUsage/wallpaper.log"))
        XCTAssertTrue(exists("Library/Application Support/TrackMyUsage/original-wallpaper.txt"))
        XCTAssertFalse(exists("Library/Caches/Claudruple"))
        XCTAssertFalse(exists("Library/Logs/Claudruple"))

        // Untouched. This is the assertion the whole design exists to make true: the profile
        // path is compiled into the clone's launcher shim, so moving it signs the account out.
        XCTAssertTrue(
            exists("Library/Application Support/Claudruple/Claude Two/Preferences"),
            "The instance profile must still be exactly where the launcher shim expects it.")
        XCTAssertTrue(
            exists("Library/Application Support/Claudruple/Claude Two/Local Storage/db"))

        // The self-referential pristine was forgotten rather than carried across.
        let state = home.appendingPathComponent(
            "Library/Caches/TrackMyUsage/wallpaper/state.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: state)) as? [String: Any])
        let displays = try XCTUnwrap(root["displays"] as? [String: Any])
        let screen = try XCTUnwrap(displays["screen-1"] as? [String: Any])
        XCTAssertNil(
            screen["pristine"],
            """
            A remembered wallpaper pointing at one of our own renders survived the move. \
            The daemon would composite the overlay onto a previous overlay, darkening the \
            desktop a little every five minutes, and report nothing.
            """)
    }

    func testRunningItTwiceChangesNothingTheSecondTime() throws {
        try stageLegacyInstall()
        let files = SystemFileMover()
        let environment = MigrationEnvironment(
            home: home, exists: { files.exists($0) }, hasLegacyKeychainItems: { false })

        func run() -> MigrationReceipt {
            MigrationRunner(
                home: home, files: files, keychain: FakeKeychain(), launchctl: FakeLaunchctl(),
                legacyKeychainService: "old", newKeychainService: "new"
            ).run(MigrationPlan.probe(environment))
        }

        _ = run()
        let before = try snapshotTree()
        let second = run()
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(before, try snapshotTree(), "A second run must be a no-op.")
    }

    // MARK: -

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    private func snapshotTree() throws -> [String] {
        guard
            let walker = FileManager.default.enumerator(
                at: home, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap {
            ($0 as? URL)?.path.replacingOccurrences(of: home.path, with: "")
        }
        .sorted()
    }
}
