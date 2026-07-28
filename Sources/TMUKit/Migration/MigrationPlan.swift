import Foundation

/// What migration would do, decided without doing any of it.
///
/// Pure given its environment: every question about the world arrives as a closure, so the
/// planner can be tested exhaustively against states that are awkward to create on a real
/// machine — half-migrated, agents installed but caches already moved, and so on.
///
/// The same split as `SyncPlan`/`SyncApplier`, for the same reason: a plan you can print is
/// a plan you can disagree with before it runs.
public struct MigrationPlan: Equatable, Sendable {

    public let steps: [MigrationStep]

    public var isEmpty: Bool { steps.isEmpty }

    /// Decide the work. Nothing here touches disk; `env` answers every question.
    public static func probe(_ env: MigrationEnvironment) -> MigrationPlan {
        var steps: [MigrationStep] = []

        if env.hasLegacyKeychainItems() {
            steps.append(.keychain)
        }

        let caches = LegacyPaths.caches(home: env.home)
        if env.exists(caches.old) && !env.exists(caches.new) {
            steps.append(.caches)
            // Only worth scrubbing if there is a state file to scrub. It moves with the
            // directory, so this is conditional on the move, not independent of it.
            if env.exists(caches.old.appendingPathComponent("wallpaper/state.json")) {
                steps.append(.wallpaperState)
            }
        }

        let logs = LegacyPaths.logs(home: env.home)
        if env.exists(logs.old) && !env.exists(logs.new) {
            steps.append(.logs)
        }

        let support = LegacyPaths.instanceSupportDirectory(home: env.home)
        let owned = LegacyPaths.ownedFilesInInstanceSupport
            .map(support.appendingPathComponent)
            .filter(env.exists)
        if !owned.isEmpty {
            steps.append(.ownedFiles)
        }

        if LegacyPaths.agents.contains(where: { env.exists($0.oldPlist(home: env.home)) }) {
            steps.append(.agents)
        }

        return MigrationPlan(steps: steps)
    }

    /// Guard used by the tests: no step may name the instance profile root.
    ///
    /// Migrating that directory signs every account out — the profile path is compiled into
    /// each clone's launcher shim, so moving the data does not move what reads it. The rule
    /// is asserted rather than merely documented because the failure is silent.
    public func touchesInstanceProfiles(home: URL) -> Bool {
        // .ownedFiles reaches *into* that directory for named files, which is allowed; a
        // step that moves the directory itself is not, and none may exist.
        steps.contains { step in
            switch step {
            case .keychain, .caches, .wallpaperState, .logs, .agents:
                return false
            case .ownedFiles:
                return false  // named files only — see LegacyPaths.ownedFilesInInstanceSupport
            }
        }
    }
}

public enum MigrationStep: String, Codable, CaseIterable, Sendable {
    /// Relabel keychain items onto the new service, in place, without reading them.
    case keychain
    /// `~/Library/Caches/Claudruple` → `.../TrackMyUsage`.
    case caches
    /// Null any remembered wallpaper that points at one of our own renders.
    case wallpaperState
    /// Files we own that live beside instance profiles.
    case ownedFiles
    /// `~/Library/Logs/Claudruple` → `.../TrackMyUsage`. Before `agents`.
    case logs
    /// Relabel the launch agents.
    case agents
}

/// Every question the planner asks about the world.
public struct MigrationEnvironment: Sendable {
    public let home: URL
    public let exists: @Sendable (URL) -> Bool
    public let hasLegacyKeychainItems: @Sendable () -> Bool

    public init(
        home: URL,
        exists: @escaping @Sendable (URL) -> Bool,
        hasLegacyKeychainItems: @escaping @Sendable () -> Bool
    ) {
        self.home = home
        self.exists = exists
        self.hasLegacyKeychainItems = hasLegacyKeychainItems
    }
}
