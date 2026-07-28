import XCTest

@testable import TMUKit

/// Removal is the only destructive thing sync does, so the rules around it are pinned
/// down harder than anything else in the planner.
final class DriftPolicyTests: XCTestCase {

    /// Mirrors the real two-account case: the manifest manages `a` and `b`, and the
    /// instance additionally carries `blender` (deliberate, exempted) and `stray`
    /// (installed out-of-band, unmanaged).
    private let spec = InstanceSpec(
        name: "Work",
        extensions: ["a", "b"],
        keep: ["blender"])

    private let state = InstanceState(
        name: "Work",
        extensions: ["a", "blender", "stray", "zebra"],
        configKeys: [])

    // MARK: - Additive is the default and never destroys

    func testAdditiveNeverRemovesAnything() {
        XCTAssertEqual(SyncPlan.removals(spec: spec, state: state, policy: .additive), [])
    }

    func testDefaultPolicyIsAdditive() {
        let plan = SyncPlan.between(spec: spec, state: state)
        XCTAssertEqual(plan.removals, [], "omitting a policy must not delete anything")
    }

    // MARK: - Exact converges

    func testExactRemovesUnmanagedExtensions() {
        XCTAssertEqual(
            SyncPlan.removals(spec: spec, state: state, policy: .exact),
            ["stray", "zebra"])
    }

    func testKeepListExemptsExtensionsFromRemoval() {
        let removals = SyncPlan.removals(spec: spec, state: state, policy: .exact)
        XCTAssertFalse(
            removals.contains("blender"),
            "keep: exists so exact stays usable without losing deliberate one-offs")
    }

    func testManagedExtensionsAreNeverRemoved() {
        let removals = SyncPlan.removals(spec: spec, state: state, policy: .exact)
        XCTAssertFalse(removals.contains("a"))
    }

    func testRemovalsAreSortedForStableOutput() {
        // A plan a user reviews must not reorder itself between runs.
        XCTAssertEqual(
            SyncPlan.removals(spec: spec, state: state, policy: .exact),
            ["stray", "zebra"].sorted())
    }

    // MARK: - Authorisation lives on the command line, not in the manifest

    func testExactDowngradesToAdditiveWithoutPruneAuthorisation() {
        // A manifest pulled from someone else's dotfiles must not be able to delete
        // extensions merely by declaring `policy: exact`.
        XCTAssertEqual(DriftPolicy.exact.effective(pruneAuthorized: false), .additive)
    }

    func testExactSurvivesWhenPruneIsAuthorised() {
        XCTAssertEqual(DriftPolicy.exact.effective(pruneAuthorized: true), .exact)
    }

    func testPruneAloneDoesNotUpgradeAnAdditiveManifest() {
        // --prune authorises removal; it does not opt you into convergence.
        XCTAssertEqual(DriftPolicy.additive.effective(pruneAuthorized: true), .additive)
    }

    // MARK: - The plan carries removals

    func testPlanUnderExactReportsBothInstallsAndRemovals() {
        let plan = SyncPlan.between(spec: spec, state: state, policy: .exact)
        XCTAssertEqual(plan.installs, ["b"])
        XCTAssertEqual(plan.removals, ["stray", "zebra"])
        XCTAssertFalse(plan.isEmpty)
    }

    func testPlanIsNotEmptyWhenOnlyRemovalsRemain() {
        let converged = InstanceSpec(name: "Work", extensions: ["a"], keep: [])
        let drifted = InstanceState(name: "Work", extensions: ["a", "stray"], configKeys: [])

        let plan = SyncPlan.between(spec: converged, state: drifted, policy: .exact)

        XCTAssertTrue(plan.installs.isEmpty)
        XCTAssertFalse(plan.isEmpty, "a plan with removals still has work to do")
    }
}
