import Foundation

/// How `sync` treats extensions installed on an instance that the manifest does not list.
///
/// This is a policy decision, not a technical one, and it is the difference between a
/// manifest that *describes* an instance and one that merely *seeds* it.
///
/// Real case from a two-account install: the primary carries 15 extensions, the second
/// instance 9 — but the second has `blender-mcp`, which the primary does not. Capturing a
/// manifest from the primary and applying it to the second gives 16 extensions under
/// `.additive`, and 15 under `.exact` unless blender is named in `keep:`.
public enum DriftPolicy: String, Sendable, CaseIterable {
    /// Install what is missing; never remove. The default.
    case additive
    /// Converge exactly: anything absent from both `extensions:` and `keep:` is removed.
    case exact

    /// The policy that actually applies, given whether removal was authorised on the
    /// command line.
    ///
    /// Removal requires `--prune` even when the manifest asks for `exact`. Manifests are
    /// meant to be shared — committed to dotfiles repos, copied between machines — and a
    /// file someone else wrote must not be able to delete your extensions just by
    /// declaring a policy. Authorisation belongs to the person running the command.
    ///
    /// Note this only ever downgrades: `--prune` authorises removal, it does not opt an
    /// additive manifest into convergence.
    public func effective(pruneAuthorized: Bool) -> DriftPolicy {
        pruneAuthorized ? self : .additive
    }
}

extension SyncPlan {
    /// Extension IDs that `apply` should uninstall, sorted for stable output.
    ///
    /// Under `.additive` this is always empty. Under `.exact` it is everything installed
    /// that the manifest neither manages nor exempts.
    public static func removals(
        spec: InstanceSpec,
        state: InstanceState,
        policy: DriftPolicy
    ) -> [String] {
        guard policy == .exact else { return [] }
        return state.extensions
            .subtracting(spec.extensions)
            .subtracting(spec.keep)
            .sorted()
    }
}
