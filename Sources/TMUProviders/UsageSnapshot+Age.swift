import Foundation

extension UsageSnapshot {

    /// How long ago this reading was taken.
    ///
    /// The SDK reports *age* and never *policy*. Whether a given age counts as stale is a
    /// display decision that belongs to TMUDesign, and putting the threshold here would
    /// force this target — which deliberately depends on nothing — to have an opinion about
    /// how it is drawn.
    ///
    /// Negative ages are clamped to zero. A reading stamped slightly in the future is a
    /// clock skew, not a prophecy, and letting it go negative would make it read as fresher
    /// than fresh.
    public func age(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(observedAt))
    }
}
