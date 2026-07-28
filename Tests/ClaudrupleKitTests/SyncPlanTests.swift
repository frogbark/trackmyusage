import XCTest

@testable import ClaudrupleKit

/// The planner turns "what the manifest says" plus "what an instance actually has" into
/// an explicit list of actions. It is deliberately pure: no filesystem, no side effects,
/// so `sync plan` can show exactly what `sync apply` would do.
final class SyncPlanTests: XCTestCase {

    private let manifest = InstanceSpec(
        name: "Work",
        extensions: [
            "ant.dir.ant.anthropic.filesystem",
            "ant.dir.gh.stripe.stripe",
            "ant.dir.gh.figma.figma",
        ])

    // MARK: - Installing what is missing

    func testPlansInstallsForExtensionsMissingFromTheTarget() {
        let state = InstanceState(
            name: "Work",
            extensions: ["ant.dir.ant.anthropic.filesystem"],
            configKeys: [])

        let plan = SyncPlan.between(spec: manifest, state: state)

        XCTAssertEqual(
            plan.installs, ["ant.dir.gh.figma.figma", "ant.dir.gh.stripe.stripe"],
            "installs should be the manifest's extensions minus what is present, sorted")
    }

    func testConvergedInstanceProducesAnEmptyPlan() {
        let state = InstanceState(
            name: "Work",
            extensions: Set(manifest.extensions),
            configKeys: [])

        let plan = SyncPlan.between(spec: manifest, state: state)

        XCTAssertTrue(plan.isEmpty, "a converged instance needs no actions")
        XCTAssertTrue(plan.installs.isEmpty)
    }

    // MARK: - The security boundary

    func testAccountScopedKeysAreNeverProposedForSync() {
        let state = InstanceState(
            name: "Work",
            extensions: [],
            configKeys: [
                "dockBounceEnabled",  // environment — syncable
                "bypassPermissionsGateByAccount",  // account     — must be refused
                "oauth:tokenCacheV2",  // account     — must be refused
                "Cookies",  // machine     — must be refused
            ])

        let plan = SyncPlan.between(spec: manifest, state: state)

        XCTAssertEqual(plan.syncableConfigKeys, ["dockBounceEnabled"])
        XCTAssertEqual(
            Set(plan.refused.map(\.key)),
            ["bypassPermissionsGateByAccount", "oauth:tokenCacheV2", "Cookies"])
    }

    func testRefusalsRecordTheirReasonSoPlanOutputCanExplainItself() {
        let state = InstanceState(
            name: "Work", extensions: [],
            configKeys: ["bypassPermissionsGateByAccount", "GPUCache"])

        let plan = SyncPlan.between(spec: manifest, state: state)
        let byKey = Dictionary(uniqueKeysWithValues: plan.refused.map { ($0.key, $0.scope) })

        XCTAssertEqual(byKey["bypassPermissionsGateByAccount"], .account)
        XCTAssertEqual(byKey["GPUCache"], .machine)
    }
}
