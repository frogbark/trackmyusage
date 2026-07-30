import XCTest

@testable import TMUKit

final class InstanceLocatorTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/example")

    func testPrimaryUsesTheStockProfilePath() {
        // The stock app is never managed by TrackMyUsage, and its profile stays where
        // Claude Desktop puts it.
        let url = InstanceLocator.profileURL(
            bundleID: "com.anthropic.claudefordesktop", displayName: "Claude", home: home)

        XCTAssertEqual(url.path, "/Users/example/Library/Application Support/Claude")
    }

    func testClonesAreNamespacedUnderTrackMyUsage() {
        let url = InstanceLocator.profileURL(
            bundleID: "com.anthropic.claudefordesktop.claudruple.two",
            displayName: "Claude Two", home: home)

        XCTAssertEqual(
            url.path, "/Users/example/Library/Application Support/Claudruple/Claude Two")
    }

    func testProfilePathMatchesWhatTheLauncherShimBakesIn() {
        // create-instance.sh compiles the shim with
        //   USER_DATA_DIR="$HOME/Library/Application Support/Claudruple/$NAME"
        // If this derivation and that string ever disagree, the CLI would silently
        // inspect a different directory than the app actually uses.
        let name = "Work"
        let url = InstanceLocator.profileURL(
            bundleID: "com.anthropic.claudefordesktop.claudruple.work",
            displayName: name, home: home)

        XCTAssertEqual(
            url.path, "/Users/example/Library/Application Support/Claudruple/\(name)")
    }

    func testBrokerIsNotAnInstance() {
        XCTAssertFalse(InstanceLocator.isClaudeInstance(bundleID: "com.trackmyusage.link"))
    }

    func testHelperBundlesAreNotInstances() {
        // Electron's XPC helpers share the prefix but are nested inside a parent bundle.
        XCTAssertFalse(
            InstanceLocator.isClaudeInstance(
                bundleID: "com.anthropic.claudefordesktop.helper"))
    }

    func testStockAppAndClonesAreInstances() {
        XCTAssertTrue(
            InstanceLocator.isClaudeInstance(bundleID: "com.anthropic.claudefordesktop"))
        XCTAssertTrue(
            InstanceLocator.isClaudeInstance(
                bundleID: "com.anthropic.claudefordesktop.claudruple.two"))
    }
}

/// Discovery against real bundles on disk.
///
/// The freshness tests exercise `compare` with strings, which proves the comparison and
/// nothing about where the strings come from. Everything above this exercises path
/// derivation, which reads no bundles at all. So a single typo — `CFBundleVersion` for
/// `CFBundleShortVersionString`, a key that exists and holds a different number — would
/// pass the entire suite and report every clone as out of step forever.
///
/// These build minimal bundles in a temp directory and run the real discovery over them.
final class InstanceDiscoveryOnDiskTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Prevents: reading the wrong Info.plist key, which no string-level test can see.
    func testTheVersionIsReadFromTheBundleAndComparedAgainstThePrimary() throws {
        let primary = try bundle(
            "Claude", id: InstanceLocator.primaryBundleID, version: "1.24012.9")
        let instances = root.appendingPathComponent("Instances")
        try FileManager.default.createDirectory(at: instances, withIntermediateDirectories: true)
        _ = try bundle(
            "Work", id: cloneID("work"), version: "1.24012.9", displayName: "Work",
            in: instances)
        _ = try bundle(
            "Old", id: cloneID("old"), version: "1.24011.2", displayName: "Old",
            in: instances)

        let found = InstanceLocator.discover(
            home: root, primaryPath: primary.path, instancesPath: instances.path)

        XCTAssertEqual(found.installedClaudeVersion, "1.24012.9")
        XCTAssertEqual(
            Set(found.map(\.name)), ["Claude", "Work", "Old"],
            "discovery did not read every bundle")
        XCTAssertEqual(found.needingRefresh.map(\.name), ["Old"])
        XCTAssertEqual(
            found.freshness().first(where: { $0.instance.name == "Old" })?.freshness,
            .stale(clone: "1.24011.2", installed: "1.24012.9"))
    }

    /// Prevents: a bundle with no version string crashing discovery or reading as current.
    func testABundleWithoutAVersionIsDiscoveredAndReportedUnknown() throws {
        let primary = try bundle(
            "Claude", id: InstanceLocator.primaryBundleID, version: "1.24012.9")
        let instances = root.appendingPathComponent("Instances")
        try FileManager.default.createDirectory(at: instances, withIntermediateDirectories: true)
        _ = try bundle(
            "Mystery", id: cloneID("mystery"), version: nil, displayName: "Mystery",
            in: instances)

        let found = InstanceLocator.discover(
            home: root, primaryPath: primary.path, instancesPath: instances.path)

        XCTAssertEqual(found.count, 2, "a versionless bundle should still be found")
        XCTAssertNil(found.first(where: { $0.name == "Mystery" })?.version)
        XCTAssertEqual(
            found.freshness().first(where: { $0.instance.name == "Mystery" })?.freshness,
            .unknown)
        XCTAssertTrue(found.needingRefresh.isEmpty, "unknown must not ask for a re-clone")
    }

    // MARK: - Fixtures

    private func cloneID(_ slug: String) -> String {
        "\(InstanceLocator.claudeBundlePrefix).\(LegacyNames.instanceBundleInfix).\(slug)"
    }

    @discardableResult
    private func bundle(
        _ name: String, id: String, version: String?, displayName: String? = nil,
        in parent: URL? = nil
    ) throws -> URL {
        let app = (parent ?? root).appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        // CFBundleName stays "Claude" on every clone, exactly as create-instance.sh leaves
        // it, so the fixture exercises the same display-name fallback the real bundles do.
        var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Claude"]
        if let version { plist["CFBundleShortVersionString"] = version }
        if let displayName { plist["CFBundleDisplayName"] = displayName }

        try (plist as NSDictionary).write(
            to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
