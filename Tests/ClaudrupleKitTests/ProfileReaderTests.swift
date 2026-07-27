import XCTest
@testable import ClaudrupleKit

/// Reads a real instance profile off disk. Tested against real temp directories rather
/// than a mocked FileManager: the interesting cases here *are* filesystem cases —
/// missing directories, stray dotfiles, malformed JSON — and a mock would only assert
/// that the mock behaves as written.
final class ProfileReaderTests: XCTestCase {

    private var profile: URL!

    override func setUpWithError() throws {
        profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudruple-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: profile)
    }

    // MARK: - Helpers

    private func makeExtension(_ id: String) throws {
        try FileManager.default.createDirectory(
            at: profile.appendingPathComponent("Claude Extensions/\(id)"),
            withIntermediateDirectories: true)
    }

    private func writeConfig(_ json: String) throws {
        try json.write(
            to: profile.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Extensions

    func testReadsInstalledExtensionIDs() throws {
        try makeExtension("ant.dir.gh.stripe.stripe")
        try makeExtension("ant.dir.ant.anthropic.filesystem")

        let state = try ProfileReader.read(name: "Work", profileURL: profile)

        XCTAssertEqual(
            state.extensions,
            ["ant.dir.gh.stripe.stripe", "ant.dir.ant.anthropic.filesystem"])
    }

    func testIgnoresDotfilesAmongExtensions() throws {
        try makeExtension("ant.dir.gh.stripe.stripe")
        try "".write(
            to: profile.appendingPathComponent("Claude Extensions/.DS_Store"),
            atomically: true, encoding: .utf8)

        let state = try ProfileReader.read(name: "Work", profileURL: profile)

        XCTAssertEqual(state.extensions, ["ant.dir.gh.stripe.stripe"])
    }

    func testIgnoresLooseFilesAmongExtensions() throws {
        // An extension is a directory. A stray file is not one, however it got there.
        try makeExtension("real.extension")
        try "junk".write(
            to: profile.appendingPathComponent("Claude Extensions/notes.txt"),
            atomically: true, encoding: .utf8)

        let state = try ProfileReader.read(name: "Work", profileURL: profile)

        XCTAssertEqual(state.extensions, ["real.extension"])
    }

    func testMissingExtensionsDirectoryReadsAsEmpty() throws {
        // A freshly created instance has no extensions directory yet. That is a valid
        // state to sync *into*, not an error.
        let state = try ProfileReader.read(name: "Fresh", profileURL: profile)
        XCTAssertEqual(state.extensions, [])
    }

    // MARK: - Config keys

    func testReadsTopLevelConfigKeys() throws {
        try writeConfig(#"{"dockBounceEnabled": true, "oauth:tokenCacheV2": "secret"}"#)

        let state = try ProfileReader.read(name: "Work", profileURL: profile)

        XCTAssertEqual(state.configKeys, ["dockBounceEnabled", "oauth:tokenCacheV2"])
    }

    func testMissingConfigReadsAsEmpty() throws {
        let state = try ProfileReader.read(name: "Fresh", profileURL: profile)
        XCTAssertEqual(state.configKeys, [])
    }

    func testMalformedConfigIsAnError() throws {
        // Reading this as "no keys" would let a corrupt profile look like a clean one, and
        // sync would then happily report nothing to do.
        try writeConfig("{ this is not json")

        XCTAssertThrowsError(try ProfileReader.read(name: "Work", profileURL: profile)) { error in
            guard case .unreadableConfig = error as? ProfileError else {
                return XCTFail("expected unreadableConfig, got \(error)")
            }
        }
    }

    // MARK: - Values are never read

    func testOnlyKeyNamesAreRetainedNotValues() throws {
        // The reader exists to classify keys. Pulling credential *values* into memory
        // would serve no purpose and widen the blast radius of any later bug.
        try writeConfig(#"{"oauth:tokenCacheV2": "super-secret-token"}"#)

        let state = try ProfileReader.read(name: "Work", profileURL: profile)

        XCTAssertEqual(state.configKeys, ["oauth:tokenCacheV2"])
        XCTAssertFalse(
            "\(state)".contains("super-secret-token"),
            "no credential value should survive into InstanceState")
    }
}
