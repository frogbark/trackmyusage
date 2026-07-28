import SwiftUI
import TMUDesign

/// The three-bar mark, drawn rather than shipped as an image.
///
/// The design asks for a menu-bar *template* image whose third bar tints warn or over. Those
/// two requirements are mutually exclusive: a template image is monochrome by definition —
/// AppKit throws its colour away and re-tints the whole thing to match the menu bar. Drawing
/// it as a `Path` satisfies both, adds no binary to the repository, needs no build step, and
/// is Retina-correct for free.
///
/// The geometry is the brand spec: heights 17/31/47 in an 84pt tile, bar width 11, gap 6,
/// corner radius 3. Everything scales from that ratio, so the same code serves the menu bar
/// glyph, the app icon and the website mark.
public struct MarkGlyph: View {

    /// The state of the *worst* reading, which is what the third bar reports.
    public let peak: UsageState
    public let isStale: Bool

    public init(peak: UsageState = .ok, isStale: Bool = false) {
        self.peak = peak
        self.isStale = isStale
    }

    /// Design-space constants, from the brand spec.
    static let tile: CGFloat = 84
    static let heights: [CGFloat] = [17, 31, 47]
    static let barWidth: CGFloat = 11
    static let gap: CGFloat = 6

    static var designWidth: CGFloat {
        CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    }

    public var body: some View {
        Canvas { context, size in
            let scale = size.height / Self.tile
            let width = Self.barWidth * scale
            let gap = Self.gap * scale
            let radius = 3 * scale

            for (index, height) in Self.heights.enumerated() {
                let barHeight = height * scale
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap),
                    y: size.height - barHeight,
                    width: width, height: barHeight)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: radius),
                    with: .color(colour(for: index)))
            }
        }
        .frame(width: Self.designWidth / Self.tile * 16, height: 16)
        // Stale mutes the whole mark, matching what the `?` suffix says beside it — the
        // reading is not necessarily wrong, but it is not necessarily now.
        .opacity(isStale ? 0.55 : 1)
    }

    /// Bars one and two carry the menu bar's own foreground so the glyph adapts to light and
    /// dark and to the highlighted state; only the third reports.
    private func colour(for index: Int) -> Color {
        guard index == Self.heights.count - 1 else { return .primary }
        switch peak {
        case .warn, .over: return Color(peak.ink)
        case .ok, .nodata, .uncapped: return .primary
        }
    }
}
