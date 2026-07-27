import Foundation

/// What a manifest says an instance should look like.
public struct InstanceSpec: Sendable, Equatable {
    public let name: String
    /// Extensions the manifest manages: installed if missing.
    public let extensions: [String]
    /// Extensions the manifest does not manage but must never remove. Exists so `.exact`
    /// stays usable without sacrificing deliberate per-instance one-offs.
    public let keep: [String]

    public init(name: String, extensions: [String], keep: [String] = []) {
        self.name = name
        self.extensions = extensions
        self.keep = keep
    }
}

/// What an instance actually looks like on disk right now.
public struct InstanceState: Sendable, Equatable {
    public let name: String
    public let extensions: Set<String>
    public let configKeys: Set<String>

    public init(name: String, extensions: Set<String>, configKeys: Set<String>) {
        self.name = name
        self.extensions = extensions
        self.configKeys = configKeys
    }
}

/// A configuration key the planner declined to sync, and why.
public struct Refusal: Sendable, Equatable {
    public let key: String
    public let scope: ConfigScope
}

/// The difference between a spec and an instance's actual state, as explicit actions.
///
/// Pure by design — no filesystem access — so `sync plan` and `sync apply` compute the
/// same thing and the printed plan is guaranteed to be what would run.
public struct SyncPlan: Sendable, Equatable {
    /// Extension IDs present in the spec but missing from the instance.
    public let installs: [String]
    /// Extension IDs to uninstall. Always empty unless the policy is `.exact`.
    public let removals: [String]
    /// Config keys that are safe to carry across instances.
    public let syncableConfigKeys: [String]
    /// Keys deliberately excluded, with the scope that disqualified them. Surfaced rather
    /// than dropped: a user who cannot see what was skipped cannot tell a safety refusal
    /// from a bug.
    public let refused: [Refusal]

    public var isEmpty: Bool { installs.isEmpty && removals.isEmpty }

    /// The policy defaults to `.additive` so that every path which forgets to pass one
    /// is non-destructive. Callers opt into removal explicitly; they never fall into it.
    public static func between(
        spec: InstanceSpec,
        state: InstanceState,
        policy: DriftPolicy = .additive
    ) -> SyncPlan {
        let installs = Set(spec.extensions)
            .subtracting(state.extensions)
            .sorted()

        var syncable: [String] = []
        var refused: [Refusal] = []
        for key in state.configKeys.sorted() {
            let scope = ConfigScope.of(key)
            if scope.isSyncable {
                syncable.append(key)
            } else {
                refused.append(Refusal(key: key, scope: scope))
            }
        }

        return SyncPlan(
            installs: installs,
            removals: removals(spec: spec, state: state, policy: policy),
            syncableConfigKeys: syncable,
            refused: refused)
    }
}
