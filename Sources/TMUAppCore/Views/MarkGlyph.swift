import SwiftUI
import TMUDesign

/// The three-bar mark, drawn rather than shipped as an image.
///
/// The design asks for a menu-bar *template* image whose third bar tints warn or over. Those
/// two requirements are mutually exclusive: a template image is monochrome by definition —
/// AppKit throws its colour away and re-tints the whole thing to match the menu bar. Drawing
/// it satisfies both, adds no binary to the repository and needs no build step.
///
/// Built from three `RoundedRectangle`s rather than a `Canvas`. A `MenuBarExtra` label is
/// rasterised by AppKit into the status item rather than composited like ordinary SwiftUI,
/// and `Canvas` draws nothing there — the pill shipped showing only its percentages, with no
/// error anywhere to say the mark was missing. Plain shapes go through layout, which works.
///
/// The geometry comes from `BrandMark`, shared with the app icon and the website mark so the
/// three cannot drift: heights 17/31/47 in an 84pt tile, bar width 11, gap 6, radius 3.
public struct MarkGlyph: View {

    /// The state of the worst reading anywhere, which is what the third bar reports.
    public let peak: UsageState
    public let isStale: Bool
    /// Menu bar glyphs are 16pt tall by convention.
    public var height: CGFloat

    public init(peak: UsageState = .ok, isStale: Bool = false, height: CGFloat = 16) {
        self.peak = peak
        self.isStale = isStale
        self.height = height
    }

    /// Scaled from the tallest bar, not from the tile.
    ///
    /// `BrandMark.designTile` is 84 with the bars topping out at 47, because the app icon
    /// needs breathing room inside its rounded square. A menu bar glyph has no tile and no
    /// padding — dividing by 84 made a "16pt" glyph 9pt tall and 8.6pt wide, which on a
    /// status bar reads as nothing at all. It was there; it was a smudge.
    private var scale: CGFloat {
        height / (BrandMark.barHeights.max() ?? BrandMark.designTile)
    }

    public var body: some View {
        let scale = self.scale
        HStack(alignment: .bottom, spacing: BrandMark.barGap * scale) {
            ForEach(Array(BrandMark.barHeights.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: BrandMark.barRadius * scale, style: .continuous)
                    .fill(colour(for: index))
                    .frame(width: BrandMark.barWidth * scale, height: bar * scale)
            }
        }
        .frame(height: height, alignment: .bottom)
        // Stale mutes the whole mark, matching what the `?` beside it already says: the
        // reading is not necessarily wrong, but it is not necessarily now.
        .opacity(isStale ? 0.55 : 1)
    }

    /// Bars one and two take the menu bar's own foreground, so the glyph keeps adapting to
    /// light and dark and to the highlighted state. Only the third one reports.
    private func colour(for index: Int) -> Color {
        guard index == BrandMark.barHeights.count - 1 else { return Color(nsColor: .labelColor) }
        switch peak {
        case .warn, .over: return Color(peak.ink)
        case .ok, .nodata, .uncapped: return Color(nsColor: .labelColor)
        }
    }
}
