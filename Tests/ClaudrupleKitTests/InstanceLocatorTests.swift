import XCTest

@testable import ClaudrupleKit

final class InstanceLocatorTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/example")

    func testPrimaryUsesTheStockProfilePath() {
        // The stock app is never managed by Claudruple, and its profile stays where
        // Claude Desktop puts it.
        let url = InstanceLocator.profileURL(
            bundleID: "com.anthropic.claudefordesktop", displayName: "Claude", home: home)

        XCTAssertEqual(url.path, "/Users/example/Library/Application Support/Claude")
    }

    func testClonesAreNamespacedUnderClaudruple() {
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
        XCTAssertFalse(InstanceLocator.isClaudeInstance(bundleID: "com.claudruple.link"))
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
