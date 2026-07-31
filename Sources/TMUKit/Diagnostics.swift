import Foundation

/// What `tmu doctor` found.
///
/// The parts of this install that can go wrong go wrong quietly. An instance can be
/// unregistered, or signed with an id LaunchServices no longer associates with it, or
/// pointed at a profile directory nothing writes to — and in every one of those cases the
/// app still launches and the CLI still prints numbers. There is no error to notice.
///
/// So the checks are stated as facts that ought to be true, each one tied to what breaks
/// when it is not. Anything that cannot be established is reported as unknown rather than
/// assumed fine, on the same rule the wallpaper follows when it draws "no data" instead of
/// zero: a check that cannot see is not a check that passed.
/// What `tmu doctor` found when it looked for the widget.
///
/// Four cases rather than a Bool because two of the failures are not failures. See
/// `Diagnostics.widget(_:)` for why conflating them is the mistake worth avoiding.
public enum WidgetInstallState: String, Codable, Sendable, Equatable {
    /// Extension installed and the published telemetry is current.
    case ok
    /// Extension installed, but nothing has published recently — the app is not running.
    case frozen
    /// No extension, because this build is ad-hoc signed and cannot have one.
    case unsignedBuild
    /// No extension, on a build that should have one.
    case missing
}

public enum Diagnostics {

    public enum Level: String, Sendable, Equatable {
        case ok
        case warn
        case fail
        /// Could not be established. Distinct from `ok` on purpose.
        case unknown
    }

    public struct Finding: Sendable, Equatable {
        public let level: Level
        public let subject: String
        public let summary: String
        /// What breaks because of this, and what to do. Absent when nothing is wrong.
        public let consequence: String?

        public init(level: Level, subject: String, summary: String, consequence: String? = nil) {
            self.level = level
            self.subject = subject
            self.summary = summary
            self.consequence = consequence
        }
    }

    /// Everything the checks need, gathered by the caller.
    ///
    /// A struct of facts rather than a pile of function calls, so the rules can be tested
    /// against situations that are tedious to produce on a real machine — a shim pointing
    /// somewhere unexpected, an unregistered bundle, a missing Claude.
    public struct Input: Sendable {
        public struct Instance: Sendable {
            public let name: String
            public let bundleID: String
            public let isPrimary: Bool
            public let version: String?
            /// What `InstanceLocator` believes the profile path is.
            public let expectedProfile: String
            /// What the shim actually compiles in. Nil when it could not be read.
            public let compiledProfile: String?
            public let profileExists: Bool
            /// Nil when the check could not run.
            public let signatureValid: Bool?
            public let registeredBundleIDs: Set<String>

            public init(
                name: String, bundleID: String, isPrimary: Bool, version: String?,
                expectedProfile: String, compiledProfile: String?, profileExists: Bool,
                signatureValid: Bool?, registeredBundleIDs: Set<String>
            ) {
                self.name = name
                self.bundleID = bundleID
                self.isPrimary = isPrimary
                self.version = version
                self.expectedProfile = expectedProfile
                self.compiledProfile = compiledProfile
                self.profileExists = profileExists
                self.signatureValid = signatureValid
                self.registeredBundleIDs = registeredBundleIDs
            }
        }

        public let claudeInstalled: Bool
        public let claudeVersion: String?
        public let instances: [Instance]
        public let brokerInstalled: Bool
        public let brokerAgentLoaded: Bool
        public let brokerRunning: Bool
        public let widget: WidgetInstallState
        public let keychainReachable: Bool

        public init(
            claudeInstalled: Bool, claudeVersion: String?, instances: [Instance],
            brokerInstalled: Bool, brokerAgentLoaded: Bool, brokerRunning: Bool,
            widget: WidgetInstallState, keychainReachable: Bool
        ) {
            self.claudeInstalled = claudeInstalled
            self.claudeVersion = claudeVersion
            self.instances = instances
            self.brokerInstalled = brokerInstalled
            self.brokerAgentLoaded = brokerAgentLoaded
            self.brokerRunning = brokerRunning
            self.widget = widget
            self.keychainReachable = keychainReachable
        }
    }

    /// Every finding, in the order a person should read them.
    public static func run(_ input: Input) -> [Finding] {
        var findings: [Finding] = []
        findings += claude(input)
        for instance in input.instances { findings += self.instance(instance, in: input) }
        findings += broker(input)
        findings += widget(input)
        findings += keychain(input)
        return findings
    }

    /// True when nothing is broken. Warnings do not count — they are choices, not faults.
    public static func isHealthy(_ findings: [Finding]) -> Bool {
        !findings.contains { $0.level == .fail }
    }

    // MARK: - Checks

    private static func claude(_ input: Input) -> [Finding] {
        guard input.claudeInstalled else {
            return [
                Finding(
                    level: .fail, subject: "Claude Desktop",
                    summary: "not installed at \(InstanceLocator.primaryAppPath)",
                    consequence:
                        "Instances are clones of it. Nothing can be created or refreshed, and "
                        + "existing clones cannot be compared against anything.")
            ]
        }
        return [
            Finding(
                level: .ok, subject: "Claude Desktop",
                summary: input.claudeVersion.map { "installed, \($0)" } ?? "installed")
        ]
    }

    private static func instance(_ instance: Input.Instance, in input: Input) -> [Finding] {
        var findings: [Finding] = []
        let subject = instance.name

        // The one that matters most. If these disagree the app writes to one directory and
        // every reading the CLI reports comes from another — and both keep working.
        switch instance.compiledProfile {
        case .none where !instance.isPrimary:
            findings.append(
                Finding(
                    level: .unknown, subject: subject,
                    summary: "could not read the profile path out of the launcher",
                    consequence:
                        "It is the only record of where this instance keeps its data. Without "
                        + "it, nothing can confirm the CLI is reading what the app writes."))
        case .some(let compiled) where compiled != instance.expectedProfile:
            findings.append(
                Finding(
                    level: .fail, subject: subject,
                    summary: "the launcher and the CLI disagree about the profile",
                    consequence:
                        "app uses \(compiled)\n      CLI reads \(instance.expectedProfile)\n"
                        + "      Every figure reported for this instance belongs to a "
                        + "directory it does not write to. Recreate it."))
        default:
            break
        }

        if !instance.profileExists {
            findings.append(
                Finding(
                    level: instance.isPrimary ? .warn : .warn, subject: subject,
                    summary: "no profile directory yet",
                    consequence:
                        "Nobody has signed into this instance. It will appear with no "
                        + "readings until somebody does."))
        }

        if !instance.isPrimary {
            if !instance.registeredBundleIDs.isEmpty,
                !instance.registeredBundleIDs.contains(instance.bundleID)
            {
                findings.append(
                    Finding(
                        level: .fail, subject: subject,
                        summary: "not registered with LaunchServices as \(instance.bundleID)",
                        consequence:
                            "macOS keys activation, notifications and deep links on the "
                            + "bundle id. Re-register with lsregister -f, or refresh it."))
            }

            switch instance.signatureValid {
            case .some(false):
                findings.append(
                    Finding(
                        level: .fail, subject: subject,
                        summary: "code signature does not verify",
                        consequence:
                            "Gatekeeper may relocate it to a read-only path on next launch. "
                            + "./scripts/refresh-instance.sh \"\(instance.name)\" --force"))
            case .none:
                findings.append(
                    Finding(
                        level: .unknown, subject: subject,
                        summary: "could not check the code signature"))
            case .some(true):
                break
            }

            let freshness = InstanceFreshness.compare(
                clone: instance.version, installed: input.claudeVersion)
            if case .stale = freshness {
                findings.append(
                    Finding(
                        level: .warn, subject: subject,
                        summary: "on a different build — \(freshness.summary)",
                        consequence:
                            "Clones do not update themselves. "
                            + "./scripts/refresh-instance.sh \"\(instance.name)\""))
            }
        }

        if findings.isEmpty {
            findings.append(
                Finding(
                    level: .ok, subject: subject,
                    summary: instance.isPrimary ? "primary, untouched" : "healthy"))
        }
        return findings
    }

    private static func broker(_ input: Input) -> [Finding] {
        guard input.brokerInstalled else {
            return [
                Finding(
                    level: input.instances.count > 1 ? .fail : .warn, subject: "Deep-link broker",
                    summary: "not installed",
                    consequence:
                        "claude:// goes to whichever instance last claimed it, so sign-ins "
                        + "and MCP OAuth callbacks land in the wrong account. "
                        + "./scripts/build-link.sh && ./scripts/install-link-agent.sh")
            ]
        }
        guard input.brokerAgentLoaded else {
            return [
                Finding(
                    level: .fail, subject: "Deep-link broker",
                    summary: "installed, but its login agent is not loaded",
                    consequence:
                        "It will not come back after a reboot. "
                        + "./scripts/install-link-agent.sh")
            ]
        }
        guard input.brokerRunning else {
            return [
                Finding(
                    level: .fail, subject: "Deep-link broker",
                    summary: "agent loaded but nothing is running",
                    consequence:
                        "Callbacks arriving now are not being routed. Check "
                        + "~/Library/Logs/TrackMyUsage/link.stderr.log")
            ]
        }
        return [
            Finding(level: .ok, subject: "Deep-link broker", summary: "running, owns claude://")
        ]
    }

    /// Four outcomes, not two.
    ///
    /// The distinction that matters is `unsignedBuild` versus `missing`. An ad-hoc signature
    /// cannot carry an App Group entitlement, so a build made without a certificate has no
    /// widget by construction — it is a supported configuration and a complete app. Reporting
    /// that as damage would send every contributor without a signing identity looking for a
    /// fault that is not there.
    private static func widget(_ input: Input) -> [Finding] {
        switch input.widget {
        case .ok:
            return [
                Finding(
                    level: .ok, subject: "Usage widget",
                    summary: "installed, and the app is publishing to it")
            ]
        case .frozen:
            return [
                Finding(
                    level: .warn, subject: "Usage widget",
                    summary: "installed, but nothing has been published recently",
                    consequence: "The widget only updates while TrackMyUsage.app is running. "
                        + "It marks itself stale with `?` rather than showing a frozen number, "
                        + "but it will not change until the app is open.")
            ]
        case .unsignedBuild:
            return [
                Finding(
                    level: .warn, subject: "Usage widget",
                    summary: "not built — this app is ad-hoc signed",
                    consequence: "Not a fault. An ad-hoc signature cannot carry an App Group "
                        + "entitlement, and the widget needs one to read what the app "
                        + "publishes. Rebuild with IDENTITY set to a Developer certificate.")
            ]
        case .missing:
            return [
                Finding(
                    level: .warn, subject: "Usage widget",
                    summary: "the app is signed but carries no widget extension",
                    consequence: "Reinstall with ./scripts/build-app.sh, then check "
                        + "./scripts/check-widget.sh.")
            ]
        }
    }

    private static func keychain(_ input: Input) -> [Finding] {
        [
            Finding(
                level: input.keychainReachable ? .ok : .fail,
                subject: "Keychain",
                summary: input.keychainReachable ? "reachable" : "could not be read",
                consequence: input.keychainReachable
                    ? nil
                    : "Provider credentials cannot be looked up, so every metered service "
                        + "will report unauthorized.")
        ]
    }
}
