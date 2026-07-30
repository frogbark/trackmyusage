import Foundation
import TMUKit
import TMUProviders

/// `tmu doctor` — gather the facts, hand them to `Diagnostics`, print what came back.
///
/// The split is deliberate: everything that decides whether something is wrong lives in
/// TMUKit and is tested, and everything here reads the machine. A rule buried in a print
/// statement is a rule nobody can check.
enum Doctor {

    static func run() -> Never {
        let findings = Diagnostics.run(gather())

        print("")
        var lastSubject = ""
        for finding in findings {
            let subject = finding.subject == lastSubject ? "" : finding.subject
            lastSubject = finding.subject
            print("  \(mark(finding.level))  \(pad(subject))  \(finding.summary)")
            if let consequence = finding.consequence {
                for line in consequence.split(separator: "\n", omittingEmptySubsequences: false) {
                    print("             \(line)")
                }
            }
        }

        let failures = findings.filter { $0.level == .fail }.count
        let warnings = findings.filter { $0.level == .warn }.count
        let unknowns = findings.filter { $0.level == .unknown }.count
        print("")
        if Diagnostics.isHealthy(findings) {
            var note = "nothing broken"
            if warnings > 0 { note += " · \(warnings) worth knowing" }
            if unknowns > 0 { note += " · \(unknowns) could not be checked" }
            print("  \(note)\n")
            exit(0)
        }
        print("  \(failures) broken · \(warnings) worth knowing · \(unknowns) unchecked\n")
        // Non-zero so this can gate a script. A health check that always succeeds is a
        // health check nobody can automate.
        exit(1)
    }

    private static func mark(_ level: Diagnostics.Level) -> String {
        switch level {
        case .ok: return "\u{001B}[32mok  \u{001B}[0m"
        case .warn: return "\u{001B}[33mnote\u{001B}[0m"
        case .fail: return "\u{001B}[31mFAIL\u{001B}[0m"
        case .unknown: return "\u{001B}[90m?   \u{001B}[0m"
        }
    }

    private static func pad(_ text: String) -> String {
        text.count >= 18 ? text : text + String(repeating: " ", count: 18 - text.count)
    }

    // MARK: - Reading the machine

    private static func gather() -> Diagnostics.Input {
        let discovered = InstanceLocator.discover()
        let registered = registeredBundleIDs()
        let home = FileManager.default.homeDirectoryForCurrentUser

        let instances = discovered.map { instance -> Diagnostics.Input.Instance in
            let executable =
                Bundle(url: instance.appURL)?
                .object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            let shim = executable.map {
                instance.appURL.appendingPathComponent("Contents/MacOS/\($0)")
            }
            return Diagnostics.Input.Instance(
                name: instance.name,
                bundleID: instance.bundleID,
                isPrimary: instance.isPrimary,
                version: instance.version,
                expectedProfile: instance.profileURL.path,
                // The primary has no shim — it is the stock app — so this is only read for
                // clones, where a mismatch is the failure worth finding.
                compiledProfile: instance.isPrimary
                    ? instance.profileURL.path
                    : shim.flatMap { ShimProfile.path(ofShimAt: $0) },
                profileExists: FileManager.default.fileExists(atPath: instance.profileURL.path),
                signatureValid: instance.isPrimary ? true : verifies(instance.appURL),
                registeredBundleIDs: registered)
        }

        return Diagnostics.Input(
            claudeInstalled: FileManager.default.fileExists(
                atPath: InstanceLocator.primaryAppPath),
            claudeVersion: discovered.installedClaudeVersion,
            instances: instances,
            brokerInstalled: FileManager.default.fileExists(
                atPath: "/Applications/TrackMyUsage Link.app"),
            brokerAgentLoaded: agentLoaded("com.trackmyusage.link"),
            brokerRunning: processRunning("TrackMyUsage Link.app/Contents/MacOS"),
            wallpaperAgentLoaded: agentLoaded("com.trackmyusage.wallpaper"),
            keychainReachable: keychainReachable(home: home))
    }

    /// Whether the signature verifies. Nil when the check itself could not run, which is a
    /// different answer from "it failed".
    private static func verifies(_ url: URL) -> Bool? {
        guard let status = run("/usr/bin/codesign", ["--verify", "--strict", url.path]) else {
            return nil
        }
        return status == 0
    }

    private static func agentLoaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    private static func processRunning(_ pattern: String) -> Bool {
        run("/usr/bin/pgrep", ["-f", pattern]) == 0
    }

    /// A read that is expected to find nothing. It tests that the keychain answers at all,
    /// not that anything is stored.
    ///
    /// `secret(for:)` rather than `has`, deliberately. `has` folds every failure into false,
    /// which is right for a settings screen — an unreadable item and an absent one are both
    /// "not connected" there — and useless here, where the whole question is whether the
    /// keychain is answering. `secret` returns nil for a missing item and throws for
    /// anything else, which is the distinction this check exists to make.
    ///
    /// The first version of this called `has`, discarded the result and returned true. It
    /// would have reported a locked keychain as reachable, which is worse than not checking:
    /// a green line that means nothing still reads as reassurance.
    private static func keychainReachable(home: URL) -> Bool {
        do {
            _ = try KeychainCredentials().secret(for: "__tmu_doctor_probe__")
            return true
        } catch {
            return false
        }
    }

    private static func registeredBundleIDs() -> Set<String> {
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks"
            + "/LaunchServices.framework/Support/lsregister"
        guard let dump = capture(lsregister, ["-dump"]) else { return [] }
        // Only the ids this project cares about. The full dump is tens of megabytes and
        // parsing it properly would be a worse use of everyone's time than a filter.
        var ids: Set<String> = []
        for line in dump.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("bundle identifier:") else { continue }
            let id = trimmed.dropFirst("bundle identifier:".count)
                .trimmingCharacters(in: .whitespaces)
            if InstanceLocator.isClaudeInstance(bundleID: id) { ids.insert(id) }
        }
        return ids
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
