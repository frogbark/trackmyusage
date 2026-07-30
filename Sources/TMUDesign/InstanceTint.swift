import Foundation

/// The colour that identifies one instance.
///
/// Clones are byte copies of the same app and inherit the same icon, so the Dock, the app
/// switcher and Mission Control show several identical tiles and the only way to tell which
/// account you are about to type into is to click one. A coloured badge answers that at a
/// glance, and colour only works as identity if it is stable — the same instance must get
/// the same tint on every machine, forever.
public enum InstanceTint {

    /// Eight tints, chosen rather than computed.
    ///
    /// A hue derived arithmetically from a hash lands wherever it lands, which is how you get
    /// two instances a few degrees apart and indistinguishable at 32 points, or a muddy
    /// olive nobody would pick. Eight well-separated colours that read on a dark tile is a
    /// smaller promise that is actually kept.
    ///
    /// Deliberately not the state palette: `Ink.warn` and `Ink.over` mean "this is near its
    /// limit" everywhere else in this project, and a badge is identity, not a reading. An
    /// instance permanently wearing the warning colour would be saying something it does not
    /// mean.
    /// Every pair is at least 0.36 apart summed across RGB, which the tests assert. The
    /// first attempt at this list was picked by eye and had two pairs closer than that —
    /// a blue and an indigo, and a teal and a green — so the separation is measured rather
    /// than trusted.
    public static let palette: [Hex] = [
        Hex("#4a8ef0"),  // blue
        Hex("#c264e0"),  // orchid
        Hex("#38b6a0"),  // teal
        Hex("#e07f3f"),  // ochre
        Hex("#d8567f"),  // rose
        Hex("#8a9aa8"),  // slate
        Hex("#8ec63f"),  // lime
        Hex("#5f5fd8"),  // indigo
    ]

    /// The tint for an instance name.
    public static func tint(for name: String) -> Hex {
        palette[Int(digest(name) % UInt64(palette.count))]
    }

    /// The letter drawn on the badge, where there is room for one.
    ///
    /// First character of the name, uppercased. Two instances sharing an initial are told
    /// apart by colour, and two sharing both are a naming problem this cannot fix.
    public static func initial(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    /// FNV-1a over the name's UTF-8.
    ///
    /// Hand-rolled because `Hashable` cannot be used here: Swift seeds its hasher randomly
    /// per process, so `name.hashValue` gives a different answer on every launch. The badge
    /// would change colour each time anything regenerated it — which is the one thing a
    /// colour used as identity must never do, and it would have looked fine in every test
    /// that ran inside a single process.
    static func digest(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
