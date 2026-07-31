import XCTest

@testable import TMUKit

/// Every check `tmu doctor` makes, exercised against the situation it exists to catch.
///
/// On a working machine the command prints seven green lines, which demonstrates nothing —
/// a diagnostic that has only ever been run against a healthy install is a diagnostic nobody
/// has tested. These construct the broken states instead, most of which are tedious or
/// destructive to produce for real.
final class DiagnosticsTests: XCTestCase {

    /// Prevents: the check that matters most silently passing.
    ///
    /// The profile path is compiled into each clone's launcher and cannot be changed
    /// afterwards. If it and `InstanceLocator.profileURL` disagree, the app writes to one
    /// directory and every figure the CLI reports comes from another — and both keep
    /// working, which is why LegacyNames calls this the most dangerous of the frozen names.
    func testAProfileMismatchIsAFailureAndSaysBothPaths() throws {
        let findings = Diagnostics.run(
            input(instances: [
                instance(
                    "Work",
                    expectedProfile: "/Users/x/Library/Application Support/Claudruple/Work",
                    compiledProfile: "/Users/x/Library/Application Support/Claudruple/Old")
            ]))

        let finding = try XCTUnwrap(findings.first { $0.subject == "Work" })
        XCTAssertEqual(finding.level, .fail)
        let consequence = try XCTUnwrap(finding.consequence)
        XCTAssertTrue(
            consequence.contains("Application Support/Claudruple/Old"),
            "did not say what the app uses")
        XCTAssertTrue(
            consequence.contains("Application Support/Claudruple/Work"),
            "did not say what the CLI reads")
        XCTAssertFalse(Diagnostics.isHealthy(findings))
    }

    /// Prevents: an unreadable launcher being reported as a healthy instance.
    ///
    /// Unknown is its own level for the same reason the wallpaper draws "no data" rather
    /// than zero. A check that could not see is not a check that passed.
    func testAnUnreadableLauncherIsUnknownRatherThanHealthy() throws {
        let findings = Diagnostics.run(
            input(instances: [instance("Work", compiledProfile: nil)]))

        let finding = try XCTUnwrap(findings.first { $0.subject == "Work" })
        XCTAssertEqual(finding.level, .unknown)
        // Unknown is not a failure — it does not make the install broken, only unverified.
        XCTAssertTrue(Diagnostics.isHealthy(findings))
    }

    /// Prevents: an orphaned LaunchServices registration going unnoticed.
    func testABundleRegisteredUnderADifferentIdFails() throws {
        let findings = Diagnostics.run(
            input(instances: [
                instance("Work", bundleID: "com.example.work", registered: ["com.example.other"])
            ]))

        let finding = try XCTUnwrap(findings.first { $0.subject == "Work" })
        XCTAssertEqual(finding.level, .fail)
        XCTAssertTrue(try XCTUnwrap(finding.summary).contains("LaunchServices"))
    }

    /// Prevents: an unverifiable signature and an invalid one being reported the same way.
    func testAnInvalidSignatureFailsWhileAnUncheckableOneIsUnknown() throws {
        let invalid = Diagnostics.run(
            input(instances: [instance("Work", signatureValid: false)]))
        XCTAssertEqual(invalid.first { $0.subject == "Work" }?.level, .fail)

        let uncheckable = Diagnostics.run(
            input(instances: [instance("Work", signatureValid: nil)]))
        XCTAssertEqual(uncheckable.first { $0.subject == "Work" }?.level, .unknown)
    }

    /// Prevents: a stale clone being escalated to broken.
    ///
    /// It works, several versions behind. That is worth saying and is not a fault, and a
    /// doctor that cries failure over it teaches people to ignore it.
    func testAStaleCloneIsWorthKnowingRatherThanBroken() throws {
        let findings = Diagnostics.run(
            input(
                claudeVersion: "1.24012.9",
                instances: [instance("Work", version: "1.24011.2")]))

        let finding = try XCTUnwrap(findings.first { $0.subject == "Work" })
        XCTAssertEqual(finding.level, .warn)
        XCTAssertTrue(Diagnostics.isHealthy(findings), "a stale clone is not a broken install")
    }

    /// Prevents: the primary being judged as though it were a clone.
    ///
    /// TrackMyUsage never modifies /Applications/Claude.app, so it has no shim to read, no
    /// re-signature to verify and nothing to compare a version against.
    func testThePrimaryIsNeverFaultedForBeingItself() throws {
        let findings = Diagnostics.run(
            input(
                claudeVersion: "1.24012.9",
                instances: [
                    instance(
                        "Claude", isPrimary: true, version: "1.24012.9",
                        signatureValid: nil, registered: [])
                ]))

        XCTAssertEqual(findings.first { $0.subject == "Claude" }?.level, .ok)
    }

    /// Prevents: a missing Claude being reported as one problem among several.
    ///
    /// Nothing else can be true without it — clones are copies of it and are compared
    /// against it — so it is a failure rather than a note.
    func testWithoutClaudeInstalledNothingElseCanBeAssessed() throws {
        let findings = Diagnostics.run(input(claudeInstalled: false, claudeVersion: nil))
        let finding = try XCTUnwrap(findings.first { $0.subject == "Claude Desktop" })
        XCTAssertEqual(finding.level, .fail)
    }

    /// Prevents: the broker's absence being graded the same way whether or not it matters.
    ///
    /// With one instance there is nothing to route between and no scheme being contested.
    /// With two, deep links land in whichever account claimed the scheme last, which is the
    /// problem this project exists to solve.
    func testAMissingBrokerMattersOnlyOnceThereIsMoreThanOneInstance() throws {
        let alone = Diagnostics.run(
            input(instances: [instance("Claude", isPrimary: true)], brokerInstalled: false))
        XCTAssertEqual(alone.first { $0.subject == "Deep-link broker" }?.level, .warn)

        let several = Diagnostics.run(
            input(
                instances: [instance("Claude", isPrimary: true), instance("Work")],
                brokerInstalled: false))
        XCTAssertEqual(several.first { $0.subject == "Deep-link broker" }?.level, .fail)
    }

    /// Prevents: an installed-but-dead broker reading as working.
    ///
    /// Three states, three answers: not installed, installed but its agent is not loaded so
    /// it will not survive a reboot, and loaded but nothing running so callbacks arriving
    /// now are being dropped.
    func testTheBrokerIsJudgedOnWhetherItIsActuallyRunning() throws {
        let notLoaded = Diagnostics.run(input(brokerAgentLoaded: false, brokerRunning: false))
        XCTAssertEqual(notLoaded.first { $0.subject == "Deep-link broker" }?.level, .fail)
        XCTAssertTrue(
            try XCTUnwrap(notLoaded.first { $0.subject == "Deep-link broker" }?.summary)
                .contains("login agent"))

        let notRunning = Diagnostics.run(input(brokerAgentLoaded: true, brokerRunning: false))
        XCTAssertEqual(notRunning.first { $0.subject == "Deep-link broker" }?.level, .fail)
    }

    /// Prevents: an unreachable keychain being quiet.
    ///
    /// Every metered service reports unauthorized when this is wrong, which looks like
    /// missing credentials rather than a broken lookup.
    func testAnUnreachableKeychainIsAFailure() throws {
        let findings = Diagnostics.run(input(keychainReachable: false))
        XCTAssertEqual(findings.first { $0.subject == "Keychain" }?.level, .fail)
        XCTAssertFalse(Diagnostics.isHealthy(findings))
    }

    /// Prevents: `isHealthy` drifting to include warnings.
    ///
    /// Warnings are choices — no wallpaper agent, a clone left on an old build. Failing the
    /// exit code on those would make `tmu doctor` useless in a script, which is the only
    /// reason it has an exit code.
    func testWarningsAndUnknownsDoNotMakeAnInstallBroken() {
        let findings = [
            Diagnostics.Finding(level: .ok, subject: "a", summary: ""),
            Diagnostics.Finding(level: .warn, subject: "b", summary: ""),
            Diagnostics.Finding(level: .unknown, subject: "c", summary: ""),
        ]
        XCTAssertTrue(Diagnostics.isHealthy(findings))
        XCTAssertFalse(
            Diagnostics.isHealthy(
                findings + [Diagnostics.Finding(level: .fail, subject: "d", summary: "")]))
    }

    /// Prevents: a finding that says something is wrong without saying what to do about it.
    func testEveryFailureExplainsWhatItBreaks() {
        let findings = Diagnostics.run(
            input(
                claudeInstalled: false,
                instances: [instance("Work", compiledProfile: "/elsewhere", signatureValid: false)],
                brokerInstalled: false, keychainReachable: false))

        for finding in findings where finding.level == .fail {
            XCTAssertNotNil(
                finding.consequence, "\(finding.subject): failure with no consequence stated")
        }
    }

    // MARK: - Fixtures

    private func instance(
        _ name: String, bundleID: String = "com.anthropic.claudefordesktop.claudruple.work",
        isPrimary: Bool = false, version: String? = "1.24012.9",
        expectedProfile: String = "/Users/x/Library/Application Support/Claudruple/Work",
        compiledProfile: String? = "/Users/x/Library/Application Support/Claudruple/Work",
        profileExists: Bool = true, signatureValid: Bool? = true,
        registered: Set<String>? = nil
    ) -> Diagnostics.Input.Instance {
        Diagnostics.Input.Instance(
            name: name, bundleID: bundleID, isPrimary: isPrimary, version: version,
            expectedProfile: expectedProfile, compiledProfile: compiledProfile,
            profileExists: profileExists, signatureValid: signatureValid,
            registeredBundleIDs: registered ?? [bundleID])
    }

    func input(
        claudeInstalled: Bool = true, claudeVersion: String? = "1.24012.9",
        instances: [Diagnostics.Input.Instance] = [], brokerInstalled: Bool = true,
        brokerAgentLoaded: Bool = true, brokerRunning: Bool = true,
        widget: WidgetInstallState = .ok, keychainReachable: Bool = true
    ) -> Diagnostics.Input {
        Diagnostics.Input(
            claudeInstalled: claudeInstalled, claudeVersion: claudeVersion,
            instances: instances, brokerInstalled: brokerInstalled,
            brokerAgentLoaded: brokerAgentLoaded, brokerRunning: brokerRunning,
            widget: widget, keychainReachable: keychainReachable)
    }
}

// MARK: - Widget

extension DiagnosticsTests {

    /// The distinction the four-case enum exists for. An ad-hoc signature cannot carry an App
    /// Group entitlement, so a build made without a certificate has no widget by construction.
    /// Reporting that as damage sends every contributor without a signing identity looking for
    /// a fault that is not there.
    func testAnAdHocBuildWithNoWidgetIsNotReportedAsDamage() throws {
        let findings = Diagnostics.run(input(widget: .unsignedBuild))
        let widget = try XCTUnwrap(findings.first { $0.subject == "Usage widget" })

        XCTAssertEqual(widget.level, .warn, "a warning, not a failure")
        XCTAssertTrue(
            widget.consequence?.contains("Not a fault") ?? false,
            "it must say so in words: \(widget.consequence ?? "nil")")
    }

    /// A signed build that carries no extension is a different situation with a different fix,
    /// and the two must not read the same.
    func testAMissingExtensionOnASignedBuildIsDistinctFromAnAdHocBuild() throws {
        let missing = try XCTUnwrap(
            Diagnostics.run(input(widget: .missing)).first { $0.subject == "Usage widget" })
        let adHoc = try XCTUnwrap(
            Diagnostics.run(input(widget: .unsignedBuild)).first { $0.subject == "Usage widget" })

        XCTAssertNotEqual(missing.summary, adHoc.summary)
        XCTAssertTrue(missing.consequence?.contains("build-app.sh") ?? false)
    }

    /// A frozen widget is honest about itself — it marks its own numbers `?` — so the doctor
    /// says what to do rather than implying the data is wrong.
    func testAFrozenWidgetIsExplainedRatherThanTreatedAsAFailure() throws {
        let frozen = try XCTUnwrap(
            Diagnostics.run(input(widget: .frozen)).first { $0.subject == "Usage widget" })

        XCTAssertEqual(frozen.level, .warn)
        XCTAssertTrue(frozen.consequence?.contains("running") ?? false)
    }

    func testAWorkingWidgetReportsOk() throws {
        let ok = try XCTUnwrap(
            Diagnostics.run(input(widget: .ok)).first { $0.subject == "Usage widget" })
        XCTAssertEqual(ok.level, .ok)
    }
}
