import SwiftUI

/// Layout constants for the menu bar pill.
///
/// Here rather than inline in the Scene so the preview that renders the pill and the label
/// that ships it read the same number — a spacing tweak verified against a preview built
/// with a different value would be worth nothing.
public enum MenuBarPill {
    /// Gap between the mark and the percentages.
    ///
    /// The mark is a bitmap with no internal padding, so it sits flush at whatever this
    /// says — unlike an SF Symbol, which carries its own optical margin and would need
    /// less. Four read as cramped against the digits on a real menu bar.
    public static let markSpacing: CGFloat = 7
}
