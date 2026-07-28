import Foundation

/// Whether a reading is old enough to say so, and how to say it.
///
/// The `?` suffix is produced in exactly one function in this project. Four surfaces show
/// these numbers — the wallpaper, the menu bar pill, the popover and the instances window —
/// and the only structural way to stop them disagreeing about what counts as stale is to
/// give them one implementation rather than one convention.
public enum Freshness {

    public static func isStale(age: TimeInterval) -> Bool {
        age >= Thresholds.staleAfter
    }

    public static func isStale(observedAt: Date, now: Date) -> Bool {
        isStale(age: now.timeIntervalSince(observedAt))
    }

    /// Mark a displayed value as stale.
    ///
    /// A suffix rather than a colour change alone, because the wallpaper is read at a
    /// glance and from across a room, where a slightly duller green is not a signal. The
    /// muting is applied too — see `UsageState.ink` and the layouts — but the `?` is what
    /// actually carries.
    public static func mark(_ text: String, stale: Bool) -> String {
        stale ? text + "?" : text
    }

    /// The ink a value should use, dimmed when the reading is stale.
    ///
    /// A stale reading keeps its *state* — a stale 96% is still alarming — but loses its
    /// confidence, so it is drawn muted rather than in the state colour. Showing a stale
    /// number in full red claims a certainty about right now that we do not have.
    public static func ink(for state: UsageState, stale: Bool) -> Hex {
        stale ? Ink.muted : state.ink
    }
}
