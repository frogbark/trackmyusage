import CoreGraphics
import SwiftUI

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
}
