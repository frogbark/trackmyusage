import XCTest
@testable import ClaudrupleKit

/// The applier is the only component that writes, so its failure modes are pinned down
/// harder than anything else. Tested against real temp profiles — the interesting cases
/// are filesystem cases, and a mocked FileManager would only assert itself.
final class SyncApplierTests: XCTestCase {

    private var source: URL!
    private var target: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudruple-apply-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        target = root.appendingPathComponent("target")
        for u in [source!, target!] {
            try fm.createDirectory(
                at: u.appendingPathComponent(ProfileReader.extensionsDirectory),
                withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    @discardableResult
    private func plant(_ id: String, in profile: URL, settings: String? = nil) throws -> URL {
        let dir = profile
            .appendingPathComponent(ProfileReader.extensionsDirectory)
            .appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "payload of \(id)".write(
            to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        if let settings {
            let sdir = profile.appendingPathComponent(SyncApplier.settingsDirectory)
            try fm.createDirectory(at: sdir, withIntermediateDirectories: true)
            try settings.write(
                to: sdir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func writeRegistry(_ ids: [String], in profile: URL) throws {
        let entries = ids.map { "\"\($0)\": {\"id\": \"\($0)\", \"version\": \"1.0.0\"}" }
        let json = "{\"extensions\": {\(entries.joined(separator: ","))}}"
        try json.write(
            to: profile.appendingPathComponent(SyncApplier.registryFile),
            atomically: true, encoding: .utf8)
    }

    private func registryIDs(in profile: URL) throws -> Set<String> {
        let url = profile.appendingPathComponent(SyncApplier.registryFile)
        guard let data = fm.contents(atPath: url.path),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exts = root["extensions"] as? [String: Any]
        else { return [] }
        return Set(exts.keys)
    }

    private func installedIDs(in profile: URL) throws -> Set<String> {
        try ProfileReader.read(name: "x", profileURL: profile).extensions
    }

    private func plan(installs: [String] = [], removals: [String] = []) -> SyncPlan {
        SyncPlan(installs: installs, removals: removals, syncableConfigKeys: [], refused: [])
    }

    // MARK: - Refusing to write under a live app

    func testRefusesToWriteWhileTheTargetInstanceIsRunning() throws {
        try plant("ext.a", in: source)

        XCTAssertThrowsError(
            try SyncApplier.apply(
                plan: plan(installs: ["ext.a"]),
                from: source, to: target, targetName: "Work", running: .running)
        ) { error in
            XCTAssertEqual(error as? ApplyError, .instanceRunning(name: "Work"))
        }

        XCTAssertEqual(try installedIDs(in: target), [], "nothing may be written")
    }

    // MARK: - Installing

    func testInstallsExtensionPayload() throws {
        try plant("ext.a", in: source)
        try writeRegistry(["ext.a"], in: source)

        let result = try SyncApplier.apply(
            plan: plan(installs: ["ext.a"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertEqual(result.installed, ["ext.a"])
        XCTAssertEqual(try installedIDs(in: target), ["ext.a"])
        XCTAssertTrue(
            fm.fileExists(
                atPath: target.appendingPathComponent(
                    "\(ProfileReader.extensionsDirectory)/ext.a/manifest.json").path))
    }

    func testMergesRegistryEntryPreservingExistingOnes() throws {
        try plant("ext.a", in: source)
        try writeRegistry(["ext.a"], in: source)
        try plant("ext.existing", in: target)
        try writeRegistry(["ext.existing"], in: target)

        _ = try SyncApplier.apply(
            plan: plan(installs: ["ext.a"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertEqual(
            try registryIDs(in: target), ["ext.a", "ext.existing"],
            "merging must not drop what the target already had")
    }

    func testMissingSourceExtensionIsSkippedNotFatal() throws {
        try plant("ext.a", in: source)

        let result = try SyncApplier.apply(
            plan: plan(installs: ["ext.a", "ext.absent"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertEqual(result.installed, ["ext.a"])
        XCTAssertEqual(result.skipped.map(\.id), ["ext.absent"])
        XCTAssertEqual(
            try installedIDs(in: target), ["ext.a"],
            "one missing extension must not abort the rest of the plan")
    }

    // MARK: - Settings are credentials

    func testExtensionSettingsAreNotCopiedByDefault() throws {
        // Real finding: settings carry `api_key` (elevenlabs) and `allowed_directories`
        // (filesystem). Copying them would hand another account a credential and a
        // filesystem grant it was never given.
        try plant("ext.a", in: source, settings: #"{"userConfig":{"api_key":"sk-secret"}}"#)
        try writeRegistry(["ext.a"], in: source)

        _ = try SyncApplier.apply(
            plan: plan(installs: ["ext.a"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        let settings = target.appendingPathComponent("\(SyncApplier.settingsDirectory)/ext.a.json")
        XCTAssertFalse(fm.fileExists(atPath: settings.path))
    }

    func testSettingsAreCopiedOnlyWhenExplicitlyRequested() throws {
        try plant("ext.a", in: source, settings: #"{"userConfig":{"api_key":"sk-secret"}}"#)
        try writeRegistry(["ext.a"], in: source)

        var options = SyncApplier.Options()
        options.includeSettings = true

        _ = try SyncApplier.apply(
            plan: plan(installs: ["ext.a"]),
            from: source, to: target, targetName: "Work",
            running: .stopped, options: options)

        let settings = target.appendingPathComponent("\(SyncApplier.settingsDirectory)/ext.a.json")
        XCTAssertTrue(fm.fileExists(atPath: settings.path))
    }

    // MARK: - Removing

    func testRemovesPayloadAndRegistryEntry() throws {
        try plant("ext.gone", in: target)
        try plant("ext.stays", in: target)
        try writeRegistry(["ext.gone", "ext.stays"], in: target)

        let result = try SyncApplier.apply(
            plan: plan(removals: ["ext.gone"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertEqual(result.removed, ["ext.gone"])
        XCTAssertEqual(try installedIDs(in: target), ["ext.stays"])
        XCTAssertEqual(try registryIDs(in: target), ["ext.stays"])
    }

    func testRemovingSomethingAbsentIsNotAnError() throws {
        let result = try SyncApplier.apply(
            plan: plan(removals: ["never.installed"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertEqual(result.removed, [])
        XCTAssertEqual(result.skipped.map(\.id), ["never.installed"])
    }

    // MARK: - Backup

    func testBackupIsTakenBeforeTheFirstDestructiveWrite() throws {
        try plant("ext.gone", in: target)
        try writeRegistry(["ext.gone"], in: target)

        let result = try SyncApplier.apply(
            plan: plan(removals: ["ext.gone"]),
            from: source, to: target, targetName: "Work", running: .stopped)

        let backup = try XCTUnwrap(result.backupURL, "a removal must be recoverable")
        XCTAssertTrue(
            fm.fileExists(
                atPath: backup.appendingPathComponent(
                    "\(ProfileReader.extensionsDirectory)/ext.gone").path))
    }

    func testNoBackupIsTakenWhenNothingWouldChange() throws {
        // An empty plan should be inert — not litter a backup directory per invocation.
        let result = try SyncApplier.apply(
            plan: plan(), from: source, to: target, targetName: "Work", running: .stopped)

        XCTAssertNil(result.backupURL)
        XCTAssertTrue(result.installed.isEmpty)
    }
}
