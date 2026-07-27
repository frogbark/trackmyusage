import XCTest
@testable import ClaudrupleKit

/// Sync copies configuration between instances that belong to *different accounts*.
/// Classifying a key wrongly is not a cosmetic bug: carrying a permission grant or an
/// OAuth token across accounts is a security failure. These tests pin the policy down.
final class ConfigScopeTests: XCTestCase {

    // MARK: - Account-scoped: must never cross an instance boundary

    func testPermissionGrantsAreAccountScoped() {
        // Observed on a real install. Copying these would hand one account's
        // bypass-permissions consent to another.
        XCTAssertEqual(ConfigScope.of("bypassPermissionsGateByAccount"), .account)
        XCTAssertEqual(ConfigScope.of("bypassPermissionsOptInByAccount"), .account)
        XCTAssertEqual(ConfigScope.of("coworkModelAutoFallbackByAccount"), .account)
    }

    func testAnyByAccountSuffixIsAccountScoped() {
        // The suffix is the contract, so keys Anthropic adds later are safe by default.
        // A denylist of known names would silently start leaking on the next release.
        XCTAssertEqual(ConfigScope.of("someFutureSettingByAccount"), .account)
    }

    func testCredentialsAreAccountScoped() {
        XCTAssertEqual(ConfigScope.of("oauth:tokenCache"), .account)
        XCTAssertEqual(ConfigScope.of("oauth:tokenCacheV2"), .account)
        XCTAssertEqual(ConfigScope.of("lastKnownAccountUuid"), .account)
    }

    func testOrgScopedAllowlistCachesAreAccountScoped() {
        // Real key shape: dxt:allowlistCache:<org-uuid>. The bare key carries no org
        // and is shared policy; the suffixed one belongs to a single organisation.
        XCTAssertEqual(
            ConfigScope.of("dxt:allowlistCache:8339cad5-b54c-4416-9435-7871d6479375"), .account)
        XCTAssertEqual(
            ConfigScope.of("dxt:allowlistEnabled:4d8d3b1a-fc35-429d-beb2-4b9a8c6ab557"), .account)
    }

    func testDeviceIdentityIsAccountScoped() {
        XCTAssertEqual(ConfigScope.of("ant-device-registry.json"), .account)
        XCTAssertEqual(ConfigScope.of("ant-did"), .account)
    }

    // MARK: - Machine-scoped: local state, meaningless elsewhere

    func testCachesAreMachineScoped() {
        XCTAssertEqual(ConfigScope.of("Cache"), .machine)
        XCTAssertEqual(ConfigScope.of("Code Cache"), .machine)
        XCTAssertEqual(ConfigScope.of("GPUCache"), .machine)
        XCTAssertEqual(ConfigScope.of("DawnGraphiteCache"), .machine)
    }

    func testSessionAndWindowStateAreMachineScoped() {
        XCTAssertEqual(ConfigScope.of("Cookies"), .machine)
        XCTAssertEqual(ConfigScope.of("window-state.json"), .machine)
        XCTAssertEqual(ConfigScope.of("remoteToolsDeviceName"), .machine)
    }

    // MARK: - Environment-scoped: the whole point of sync

    func testExtensionsAndToolingAreEnvironmentScoped() {
        XCTAssertEqual(ConfigScope.of("Claude Extensions"), .environment)
        XCTAssertEqual(ConfigScope.of("Claude Extensions Settings"), .environment)
        XCTAssertEqual(ConfigScope.of("extensions-installations.json"), .environment)
    }

    func testOrdinaryPreferencesAreEnvironmentScoped() {
        XCTAssertEqual(ConfigScope.of("dockBounceEnabled"), .environment)
        XCTAssertEqual(ConfigScope.of("keepAwakeEnabled"), .environment)
        XCTAssertEqual(ConfigScope.of("sidebarMode"), .environment)
    }

    // MARK: - Precedence

    func testAccountScopeWinsOverEnvironmentLookingNames() {
        // Reads like an ordinary preference but is per-account; the suffix must dominate
        // whatever else the name resembles.
        XCTAssertEqual(ConfigScope.of("coworkModelAutoFallbackByAccount"), .account)
    }

    func testOnlySyncableScopeIsEnvironment() {
        XCTAssertTrue(ConfigScope.environment.isSyncable)
        XCTAssertFalse(ConfigScope.account.isSyncable)
        XCTAssertFalse(ConfigScope.machine.isSyncable)
    }
}
