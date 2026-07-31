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

        // Last, and after `.ownedFiles`, which is what moves original-wallpaper.txt into the
        // new support directory. The step reads both locations anyway, but running it in this
        // order means the common case reads the file where it now belongs.
        //
        // The condition is deliberately broad: any trace at all. A half-removed install — the
        // plist gone but the desktop still showing a render, or the reverse — is exactly the
        // state that needs finishing, and a narrower condition would skip it.
        let wallpaperTraces =
            LegacyPaths.wallpaperAgentLabels.map {
                LegacyPaths.launchAgentsDirectory(home: env.home)
                    .appendingPathComponent("\($0).plist")
            }
            + LegacyPaths.recordedOriginalWallpaper(home: env.home)
            + LegacyPaths.renderedWallpaperDirectories(home: env.home)
        if wallpaperTraces.contains(where: env.exists) {
            steps.append(.wallpaperTeardown)
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
            case .keychain, .caches, .wallpaperTeardown, .logs, .agents:
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
    /// Stop the wallpaper agent, put the desktop back, and delete the renders.
    ///
    /// Not a rename step. It exists because removing the wallpaper *feature* is not the same
    /// as removing it from a machine that already has it — see the comment on the runner's
    /// implementation.
    case wallpaperTeardown
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
