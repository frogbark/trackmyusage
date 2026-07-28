import XCTest

@testable import TMUKit

/// These assert literals against literals, which normally proves nothing.
///
/// Here it is the point. Each string is baked into something already on disk — a
/// LaunchServices registration, a code signature, a path compiled into a launcher shim —
/// so a "cleanup" that finishes the rename does not rename anything. It makes the existing
/// thing unreachable, with no error at any layer and no failing test anywhere else.
///
/// This is not hypothetical. The rebrand that introduced `LegacyNames` broke two of these
/// on its first attempt: the search-and-replace protected the frozen strings wherever they
/// appeared as contiguous text, and could not see them where the code assembled them from
/// parts. `InstanceLocatorTests` caught it. These tests state the rule directly, so the
/// next person gets the reason rather than a puzzling assertion about a path.
final class LegacyNamesTests: XCTestCase {

    func testTheInstanceBundleInfixIsFrozen() {
        XCTAssertEqual(
            LegacyNames.instanceBundleInfix, "claudruple",
            """
            Every instance on disk is signed with a bundle id containing this infix and \
            registered with LaunchServices under it. Changing it does not rename anything — \
            it makes every existing instance invisible to discovery.
            """)
    }

    func testTheInstancesDirectoryIsFrozen() {
        XCTAssertEqual(
            LegacyNames.instancesDirectory, "/Applications/Claudruple",
            """
            Clones live here, and the broker's LaunchAgent plist names this path absolutely. \
            The plist is not rewritten by a rebuild, so changing this constant desynchronises \
            the two.
            """)
    }

    func testTheInstanceProfileDirectoryIsFrozen() {
        XCTAssertEqual(
            LegacyNames.instanceProfileDirectory, "Claudruple",
            """
            create-instance.sh compiles this into each clone's launcher shim as \
            -DUSER_DATA_DIR, so the value is fixed in a binary at the moment the instance \
            was created and cannot be changed by editing Swift. Point Swift elsewhere and \
            the CLI inspects a directory the app does not use; point the shim elsewhere and \
            the account is signed out with every extension gone.
            """)
    }

    /// The reason the constants exist at all: the values they carry are the ones the rest of
    /// the code composes, so if the composition is wrong the constant did not help.
    func testTheComposedBundlePrefixMatchesWhatCreateInstanceAssigns() {
        // create-instance.sh line 43:
        //   BUNDLE_ID="com.anthropic.claudefordesktop.claudruple.$slug"
        let composed = "\(InstanceLocator.claudeBundlePrefix).\(LegacyNames.instanceBundleInfix)."
        XCTAssertEqual(
            composed, "com.anthropic.claudefordesktop.claudruple.",
            "This prefix and create-instance.sh must agree exactly, or no clone is found.")
    }
}
