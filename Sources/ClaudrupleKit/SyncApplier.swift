import Darwin
import Foundation

/// Whether the instance being written to is live.
///
/// A required parameter rather than something the applier works out for itself. Claude
/// Desktop reads its extension list once at startup and rewrites the registry on exit, so
/// writing underneath a running instance loses the change or corrupts the file. Making the
/// caller state this explicitly means no code path can quietly forget to check.
public enum RunningState: Sendable, Equatable {
    case running
    case stopped
}

public enum ApplyError: Error, Equatable, CustomStringConvertible {
    case instanceRunning(name: String)
    case registryUnreadable(path: String)

    public var description: String {
        switch self {
        case .instanceRunning(let name):
            return "'\(name)' is running — quit it first; Claude rewrites its extension "
                + "registry on exit and would discard these changes"
        case .registryUnreadable(let path):
            return "could not parse \(path)"
        }
    }
}

/// Something the plan named that could not be acted on.
public struct SkippedItem: Sendable, Equatable {
    public let id: String
    public let reason: String
}

public struct ApplyResult: Sendable, Equatable {
    public let installed: [String]
    public let removed: [String]
    public let skipped: [SkippedItem]
    /// Nil when the plan was empty and nothing was written.
    public let backupURL: URL?
}

/// Executes a `SyncPlan` against a profile on disk.
public enum SyncApplier {

    public static let registryFile = "extensions-installations.json"
    public static let settingsDirectory = "Claude Extensions Settings"

    public struct Options: Sendable {
        /// Copy `Claude Extensions Settings/<id>.json` alongside the payload.
        ///
        /// Off by default, and that default is a security decision rather than
        /// conservatism. On a real install these files hold `api_key` (elevenlabs) and
        /// `allowed_directories` (filesystem) — a credential and a filesystem grant. Sync
        /// moves tooling between accounts; it does not move the authority to use it. An
        /// extension arrives installed but unconfigured, which is the correct outcome.
        public var includeSettings: Bool = false
        /// Snapshot the profile before the first write. APFS clonefile, so it is
        /// effectively free and there is no reason to turn it off outside tests.
        public var backup: Bool = true
        /// Where snapshots go.
        ///
        /// Injectable because the default is the user's home directory, and a test that
        /// operates on a temp profile has no business writing there. Left hardcoded, every
        /// run of the suite deposited eight directories in `~/Claudruple-Backups` — which
        /// is exactly what happened, several hundred times, before anyone looked.
        public var backupRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Claudruple-Backups")

        public init() {}
    }

    public static func apply(
        plan: SyncPlan,
        from source: URL,
        to target: URL,
        targetName: String,
        running: RunningState,
        options: Options = Options()
    ) throws -> ApplyResult {
        guard running == .stopped else {
            throw ApplyError.instanceRunning(name: targetName)
        }
        // An empty plan is inert: no backup directory per invocation, no touched files.
        guard !plan.isEmpty else {
            return ApplyResult(installed: [], removed: [], skipped: [], backupURL: nil)
        }

        let backupURL = options.backup ? try snapshot(target, into: options.backupRoot) : nil

        var installed: [String] = []
        var removed: [String] = []
        var skipped: [SkippedItem] = []

        // Registry is read once, mutated in memory, and written once at the end, so a
        // failure partway cannot leave it half-rewritten.
        var registry = try readRegistry(in: target)
        let sourceRegistry = try readRegistry(in: source)

        for id in plan.installs {
            do {
                try installPayload(id, from: source, to: target, options: options)
                registry[id] = sourceRegistry[id] ?? registry[id]
                installed.append(id)
            } catch let e as SkipReason {
                // One missing extension must not abort the remaining work.
                skipped.append(SkippedItem(id: id, reason: e.message))
            }
        }

        for id in plan.removals {
            let dir = extensionURL(id, in: target)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                skipped.append(SkippedItem(id: id, reason: "not installed"))
                continue
            }
            try FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: settingsURL(id, in: target))
            registry.removeValue(forKey: id)
            removed.append(id)
        }

        try writeRegistry(registry, in: target)

        return ApplyResult(
            installed: installed, removed: removed, skipped: skipped, backupURL: backupURL)
    }

    // MARK: - Payload

    private struct SkipReason: Error { let message: String }

    private static func installPayload(
        _ id: String, from source: URL, to target: URL, options: Options
    ) throws {
        let src = extensionURL(id, in: source)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw SkipReason(message: "not present in source profile")
        }

        let dst = extensionURL(id, in: target)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Stage beside the destination and swap into place, so an interrupted copy leaves
        // no half-populated extension directory for Claude to load on next launch.
        let staging = dst.deletingLastPathComponent()
            .appendingPathComponent(".claudruple-staging-\(UUID().uuidString)")
        try clone(src, to: staging)

        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.moveItem(at: staging, to: dst)

        if options.includeSettings {
            let s = settingsURL(id, in: source)
            if FileManager.default.fileExists(atPath: s.path) {
                let d = settingsURL(id, in: target)
                try FileManager.default.createDirectory(
                    at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: d)
                try FileManager.default.copyItem(at: s, to: d)
            }
        }
    }

    // MARK: - Registry

    private static func readRegistry(in profile: URL) throws -> [String: Any] {
        let url = profile.appendingPathComponent(registryFile)
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ApplyError.registryUnreadable(path: url.path) }
        return (root["extensions"] as? [String: Any]) ?? [:]
    }

    private static func writeRegistry(_ extensions: [String: Any], in profile: URL) throws {
        let url = profile.appendingPathComponent(registryFile)
        let data = try JSONSerialization.data(
            withJSONObject: ["extensions": extensions],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Paths and copying

    private static func extensionURL(_ id: String, in profile: URL) -> URL {
        profile
            .appendingPathComponent(ProfileReader.extensionsDirectory)
            .appendingPathComponent(id)
    }

    private static func settingsURL(_ id: String, in profile: URL) -> URL {
        profile
            .appendingPathComponent(settingsDirectory)
            .appendingPathComponent("\(id).json")
    }

    /// APFS clonefile where possible, falling back to a normal copy.
    ///
    /// Extension payloads run to hundreds of megabytes in aggregate (700 MB on the
    /// development machine), so copy-on-write is the difference between a sync that feels
    /// instant and one that stalls. `clonefile(2)` fails on non-APFS volumes and across
    /// filesystems, hence the fallback — `FileManager` has no equivalent on macOS.
    private static func clone(_ src: URL, to dst: URL) throws {
        if clonefile(src.path, dst.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    private static func snapshot(_ profile: URL, into root: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        // A second-resolution timestamp is not a unique name. Two applies to the same
        // instance inside one second would collide, and the collision surfaces *after*
        // the running-state guard — i.e. as a mid-write failure on a real profile. The
        // random suffix costs nothing and removes the whole class.
        let token = String(UUID().uuidString.prefix(6))
        let backup = root
            .appendingPathComponent("sync-\(profile.lastPathComponent)-\(stamp)-\(token)")

        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try clone(profile, to: backup)
        return backup
    }
}
