import Foundation

/// Whether a clone still matches the Claude it was cloned from.
///
/// Clones are byte copies taken at a moment in time and they do not update themselves: when
/// Claude Desktop updates, every instance silently stays on the old build. Nothing surfaces
/// that today — the app launches, signs in and works, several versions behind, until
/// something it depends on changes server-side.
public enum InstanceFreshness: Equatable, Sendable {

    /// The clone is the same build as `/Applications/Claude.app`.
    case current

    /// The clone and the installed Claude are different builds.
    ///
    /// Deliberately not `behind`. Establishing direction means ordering two version strings,
    /// and the one case where that matters — someone reinstalling an older Claude — is
    /// exactly the case where a naive comparison gets it backwards and says "up to date"
    /// about a clone that is not. The remedy is the same in both directions: re-clone from
    /// whatever is installed now. So this reports the fact it actually has.
    case stale(clone: String, installed: String)

    /// One of the two versions could not be read.
    ///
    /// Its own case rather than folded into `current`, on the same principle the wallpaper
    /// draws "no data" instead of zero: a missing reading is not a passing one, and a clone
    /// reported as up to date on the strength of a version nobody could read is worse than
    /// one honestly marked unknown.
    case unknown

    /// True when there is something for the user to do about it.
    public var needsRefresh: Bool {
        if case .stale = self { return true }
        return false
    }

    /// How this reads in a list, in one short phrase.
    public var summary: String {
        switch self {
        case .current: return "up to date"
        case .stale(let clone, let installed): return "\(clone) → \(installed)"
        case .unknown: return "version unknown"
        }
    }

    /// Compare a clone's version against the installed Claude's.
    ///
    /// String equality rather than semantic ordering, for the reason `stale` documents: two
    /// builds either are the same or they are not, and that is the whole question a re-clone
    /// answers. It also means an unparseable or unusually-shaped version string still
    /// compares correctly instead of falling into a parser's default.
    public static func compare(clone: String?, installed: String?) -> InstanceFreshness {
        guard let clone, let installed, !clone.isEmpty, !installed.isEmpty else {
            return .unknown
        }
        return clone == installed ? .current : .stale(clone: clone, installed: installed)
    }
}
