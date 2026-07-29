import AppKit
import SwiftUI
import TMUDesign

/// The three-bar mark, drawn rather than shipped as an image.
///
/// The design asks for a menu-bar *template* image whose third bar tints warn or over. Those
/// two requirements are mutually exclusive: a template image is monochrome by definition —
/// AppKit throws its colour away and re-tints the whole thing to match the menu bar. Drawing
/// it satisfies both, adds no binary to the repository and needs no build step.
///
/// Built from three `RoundedRectangle`s, and — for the menu bar — rasterised to an `NSImage`
/// by `nsImage()` before being handed over. A `MenuBarExtra` label renders `Text` and `Image`
/// and quietly declines most else. `Canvas` drew nothing there. Shapes drew nothing there
/// either, though they draw correctly in every other context including `ImageRenderer`. In
/// both cases there was no error, no warning and no missing symbol — the pill simply came out
/// as two percentages with a gap. An `Image` is the thing the label will actually accept.
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

    /// The mark as a bitmap, for places that will not draw a view.
    ///
    /// A `MenuBarExtra` label is not an ordinary SwiftUI container. It renders `Text` and
    /// `Image` and quietly declines most else — the shapes above draw correctly everywhere
    /// they were tested, including `ImageRenderer`, and drew nothing at all in the status
    /// bar. No error, no warning, no missing symbol; the pill simply came out as two
    /// percentages with a gap where the mark should be.
    ///
    /// So the label gets an `Image` instead, rasterised here from the same view. Not a
    /// template image: those are monochrome by definition, and the third bar has to be able
    /// to turn amber, which is the one thing the mark is for at 16 points.
    ///
    /// `labelColor` is resolved against the current appearance at render time, since baking
    /// a colour into a bitmap gives up the automatic light/dark adaptation a live view had.
    /// The store refreshes every thirty seconds, so a system appearance change corrects
    /// itself within one cycle.
    /// - Parameter trailingGap: transparent space baked into the right of the bitmap.
    ///
    ///   The gap has to live *inside* the image. A `MenuBarExtra` label ignores the spacing
    ///   of the stack it is given — the same way it ignores shapes — so `HStack(spacing:)`
    ///   changes nothing on screen no matter what it says. Padding rendered into the bitmap
    ///   is geometry the status item cannot discard.
    @MainActor
    public func nsImage(appearance: NSAppearance? = nil, trailingGap: CGFloat = 0) -> NSImage? {
        let padded = self.padding(.trailing, trailingGap)
        let renderer = ImageRenderer(content: padded.environment(\.colorScheme, scheme(appearance)))
        // Never below 2x, whatever NSScreen says. The app can start before a screen is
        // known — and CI has no screen at all, where `main` reports 1x — and a menu bar
        // glyph baked at 1x stays soft for the life of the process, because this bitmap is
        // made once per refresh rather than per draw. Oversampling costs a few hundred
        // bytes and downscales cleanly on the rare non-Retina display.
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: width + trailingGap, height: height))
        image.isTemplate = false
        return image
    }

    /// How wide the mark renders, so callers can size a frame without guessing.
    public var width: CGFloat {
        let scale = self.scale
        return CGFloat(BrandMark.barHeights.count) * BrandMark.barWidth * scale
            + CGFloat(BrandMark.barHeights.count - 1) * BrandMark.barGap * scale
    }

    private func scheme(_ appearance: NSAppearance?) -> ColorScheme {
        let effective = appearance ?? NSApp?.effectiveAppearance
        let match = effective?.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
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
