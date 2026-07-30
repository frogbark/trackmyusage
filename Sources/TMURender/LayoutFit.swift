import Foundation

/// Picking a layout from the display rather than from a setting.
///
/// The three layouts are not ranked — they suit different screens. The rail reads downward
/// and wants height; the board spreads across a wide desktop; the card is what a laptop can
/// carry without the panel becoming the wallpaper. Asking someone to work that out per
/// display, for every machine they own, is a chore the shape of the screen already answers.
///
/// Judged in **points, not pixels**. Pixels measure resolution, and resolution stopped
/// tracking physical size the moment Retina existed: a 14-inch laptop is 3024×1964 and a
/// 27-inch 5K is 5120×2880, so by pixel count the laptop is merely a slightly smaller
/// monitor. In points they are 1512×982 and 2560×1440, which is the distinction that
/// matters — points are how much interface fits, and that is exactly the question here.
public enum LayoutFit {

    /// Below this height in points, the rail's rows are too small to read from where a
    /// laptop actually sits.
    ///
    /// 1000 is a decision about which mistake to make, not a measurement. Points cannot
    /// separate a 16-inch MacBook from a 24-inch 1080p monitor: both are 1080 points tall,
    /// because both genuinely fit the same amount of interface. What differs is physical
    /// size and how far away it is, which no display metric here reports —
    /// `CGDisplayScreenSize` does, in millimetres, and lies about enough hardware that
    /// depending on it would trade one wrong answer for a less predictable one.
    ///
    /// So the threshold sits between the 14-inch at 982 and everything at 1080, and the
    /// 16-inch gets the rail along with the monitors. That is the recoverable error: a rail
    /// on a large laptop is dense, while a card on a desktop monitor wastes the screen the
    /// feature exists to use. Either way `tmud layout <id> card` is one command, which is
    /// the reason a guess is allowed to be a guess.
    public static let laptopPointHeight: Double = 1000

    /// From this aspect ratio up, a desktop is wide enough that the eye would rather scan
    /// tiles across the bottom than read a column down one edge.
    ///
    /// 2.0 rather than 16:9's 1.78: an ordinary widescreen monitor is not an ultrawide, and
    /// putting the board on one would replace a layout that reads well with one that merely
    /// fits.
    public static let wideAspect: Double = 2.0

    /// The layout this display should get.
    ///
    /// `points` is the display measured in points; `designWidth` is what the renderer will
    /// actually lay out against, which is the canvas normalised to the 1440-unit design
    /// height. Both are needed: the first says how big the screen is, the second whether the
    /// board's tiles would fit at all.
    public static func layout(points: WallpaperCanvas, designWidth: Double)
        -> WallpaperLayoutID
    {
        // A degenerate display reported as zero-sized gets the default rather than a
        // division by zero. Nothing should produce this, and `resolve` would catch a bad
        // answer anyway, but a crash while enumerating screens would take the whole render.
        guard points.height > 0, points.width > 0 else { return .ledger }

        if points.height < laptopPointHeight { return .card }

        let aspect = points.width / points.height
        if aspect >= wideAspect && designWidth >= MissionBoard.minimumDesignWidth {
            return .board
        }
        return .ledger
    }
}
