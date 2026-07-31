import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The view, rasterised.
///
/// This is the impure edge, and the only one. It occupies the role `AppKitRasterizer` used to:
/// everything above it is a pure function of its inputs, and everything platform-dependent —
/// fonts, CoreGraphics, the colour space — is below it.
///
/// That boundary is why `check-generated.sh` can still do its job. The PNGs this produces are
/// not byte-reproducible between machines, for exactly the reasons the script already gives
/// for `og.png`; `web/widgets.json` is the text artifact that gets compared instead, and it
/// comes from the model this renders rather than from a second description of it.
public enum WidgetRenderer {

    /// The padding a widget host applies around its content, matched here so a rendered PNG
    /// is framed the way the placed widget is.
    public static let padding: Double = 16

    /// Renders at `scale` device pixels per point. 2 matches a Retina display.
    ///
    /// `@MainActor` because `ImageRenderer` is. It runs happily in a CLI and in a test; it is
    /// never called from the extension, which draws the real views rather than pictures of
    /// them.
    @MainActor
    public static func image(
        _ model: WidgetViewModel,
        scale: Double = 2,
        size: CGSize? = nil
    ) -> CGImage? {
        let target =
            size ?? CGSize(width: model.family.size.width, height: model.family.size.height)
        let renderer = ImageRenderer(
            content:
                UsageWidgetView(model)
                .padding(padding)
                .frame(width: target.width, height: target.height)
                .background(Color(white: 0.11))
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = scale
        return renderer.cgImage
    }

    /// The unfurl card: the widget placed on the canvas, not stretched to it.
    ///
    /// A widget has its own aspect ratio and the unfurlers crop to 1.9:1, so framing the view
    /// at the canvas size distorts it — the medium family rendered that way spreads two rows
    /// across 1200 points and leaves the bottom two-thirds empty, which advertises a layout
    /// the product does not have.
    ///
    /// So it is drawn at its true proportions, scaled up, and centred, with the rounded corner
    /// a placed widget actually has.
    @MainActor
    public static func socialCard(
        _ model: WidgetViewModel,
        canvas: CGSize,
        scale: Double = 2
    ) -> CGImage? {
        let size = model.family.size
        // Fit within the canvas with a comfortable margin, keeping the aspect ratio.
        let factor = min(canvas.width * 0.72 / size.width, canvas.height * 0.68 / size.height)
        let card = CGSize(width: size.width * factor, height: size.height * factor)

        let renderer = ImageRenderer(
            content:
                ZStack {
                    Color(white: 0.07)
                    UsageWidgetView(model)
                        .padding(padding * factor * 0.6)
                        .frame(width: card.width, height: card.height)
                        .background(Color(white: 0.13))
                        .clipShape(
                            RoundedRectangle(cornerRadius: 22 * factor / 2, style: .continuous)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 24 * factor / 2, y: 8)
                }
                .frame(width: canvas.width, height: canvas.height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = scale
        return renderer.cgImage
    }

    /// PNG bytes, for the website images and the social preview.
    ///
    /// Deliberately not byte-reproducible between machines, and that is fine here: the fonts
    /// and the CoreGraphics version decide the encoding and neither is in this repository.
    /// `check-generated.sh` excludes these for exactly the reason it already excludes og.png,
    /// and compares web/widgets.json instead — which comes from the same model these draw.
    @MainActor
    public static func png(
        _ model: WidgetViewModel,
        scale: Double = 2,
        size: CGSize? = nil,
        asCard canvas: CGSize? = nil
    ) -> Data? {
        let rendered =
            canvas.map { socialCard(model, canvas: $0, scale: scale) }
            ?? image(model, scale: scale, size: size)
        guard let image = rendered else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
