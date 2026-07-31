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
        // A wallpaper that actually exists, so the teardown can move the desktop off our
        // render and is therefore allowed to delete it. The case where the recorded original
        // has since been deleted — and the renders must be kept — is covered in MigrationTests.
        try write("jpeg", to: "Pictures/before.jpg")
        try write(
            home.appendingPathComponent("Pictures/before.jpg").path,
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
        XCTAssertEqual(plan.steps, [.caches, .logs, .ownedFiles, .wallpaperTeardown])

        let receipt = MigrationRunner(
            home: home, files: files, keychain: FakeKeychain(), launchctl: FakeLaunchctl(),
            desktop: FakeDesktop(),
            legacyKeychainService: "old", newKeychainService: "new"
        ).run(plan)

        XCTAssertTrue(receipt.isComplete, "\(receipt.outcomes)")

        // Moved.
        XCTAssertTrue(exists("Library/Logs/TrackMyUsage/wallpaper.log"))
        XCTAssertFalse(exists("Library/Caches/Claudruple"))
        XCTAssertFalse(exists("Library/Logs/Claudruple"))

        // Removed. The renders moved with the caches directory and were then deleted by the
        // teardown, and the record of the original was consumed restoring it. A machine that
        // finishes this migration has no wallpaper footprint left at all — which is the point:
        // the code is gone, so anything still pointing at it is a timer failing in silence or
        // a desktop nobody can change back.
        XCTAssertFalse(exists("Library/Caches/TrackMyUsage/wallpaper"))
        XCTAssertFalse(exists("Library/Application Support/TrackMyUsage/original-wallpaper.txt"))
        XCTAssertFalse(exists("Library/Application Support/Claudruple/original-wallpaper.txt"))

        // Untouched. This is the assertion the whole design exists to make true: the profile
        // path is compiled into the clone's launcher shim, so moving it signs the account out.
        XCTAssertTrue(
            exists("Library/Application Support/Claudruple/Claude Two/Preferences"),
            "The instance profile must still be exactly where the launcher shim expects it.")
        XCTAssertTrue(
            exists("Library/Application Support/Claudruple/Claude Two/Local Storage/db"))

    }

    func testRunningItTwiceChangesNothingTheSecondTime() throws {
        try stageLegacyInstall()
        let files = SystemFileMover()
        let environment = MigrationEnvironment(
            home: home, exists: { files.exists($0) }, hasLegacyKeychainItems: { false })

        func run() -> MigrationReceipt {
            MigrationRunner(
                home: home, files: files, keychain: FakeKeychain(), launchctl: FakeLaunchctl(),
                desktop: FakeDesktop(),
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
