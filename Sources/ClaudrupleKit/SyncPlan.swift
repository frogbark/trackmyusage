import Foundation

/// What a manifest says an instance should look like.
public struct InstanceSpec: Sendable, Equatable {
    public let name: String
    public let extensions: [String]

    public init(name: String, extensions: [String]) {
        self.name = name
        self.extensions = extensions
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
    /// Config keys that are safe to carry across instances.
    public let syncableConfigKeys: [String]
    /// Keys deliberately excluded, with the scope that disqualified them. Surfaced rather
    /// than dropped: a user who cannot see what was skipped cannot tell a safety refusal
    /// from a bug.
    public let refused: [Refusal]

    public var isEmpty: Bool { installs.isEmpty }

    public static func between(spec: InstanceSpec, state: InstanceState) -> SyncPlan {
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

        return SyncPlan(installs: installs, syncableConfigKeys: syncable, refused: refused)
    }
}
