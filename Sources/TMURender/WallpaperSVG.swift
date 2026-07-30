import Foundation
import TMUDesign
import TMUProviders
import TMUTelemetry

/// The pixel dimensions the wallpaper is being drawn for.
public struct WallpaperCanvas: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let `default` = WallpaperCanvas(width: 2560, height: 1440)
}

/// Which arrangement to draw.
///
/// This replaced `WallpaperDensity`, which conflated two independent things. Density said
/// how much to show; attention says how loudly. Once the quiet and alert states existed, a
/// single enum would have needed a case per combination, and — worse — would have implied
/// attention was a choice. It is derived from the readings (`TelemetryModel.attention`) and
/// must stay that way, or the desktop is permanently alarmed and the signal is gone.
public enum WallpaperLayoutID: String, Sendable, CaseIterable, Equatable {
    /// A left rail: every provider named and individually readable. Scales honestly to
    /// seventeen of them, and needs the vertical space to do it.
    case ledger
    /// Tiles across the bottom of a wide desktop. Same information, taken in at a glance
    /// rather than read downward.
    case board
    /// A corner card: a few providers named, the rest compressed into a strip. The laptop
    /// answer, and the one that carries the quiet/alert distinction.
    case card
}

/// The previous spelling, kept so `tmud --density compact|full` and anything scripted
/// against it keep working for a release.
@available(*, deprecated, message: "Use WallpaperLayoutID: compact -> .card, full -> .ledger")
public enum WallpaperDensity: String, Sendable, CaseIterable, Equatable {
    case compact
    case full

    public var layout: WallpaperLayoutID {
        switch self {
        case .compact: return .card
        case .full: return .ledger
        }
    }
}

/// Renders a set of provider snapshots as an SVG overlay.
///
/// Pure text in, pure text out. Keeping the whole visual design a function of its inputs is
/// what lets a layout regression fail in `swift test` rather than appear on someone's
/// desktop, and it leaves rasterising as the only step that needs a platform.
///
/// Colours are written as presentation attributes rather than collected into a `<style>`
/// block. A stylesheet would name every state in every document, which both defeats tests
/// that check whether a state is actually present and leans on CSS support that rasterisers
/// implement unevenly.
///
/// The right-hand side of the canvas is left empty. That is where desktop icons live, and a
/// panel that covers them makes the wallpaper something to be turned off. `LayoutInvariants`
/// in the tests asserts it rather than trusting each layout to remember.
public enum WallpaperSVG {

    /// How many providers the card names before compressing the remainder.
    public static let headlineCount = CompactCard.headlineCount

    // The design space is 1440 units tall and scaled to whatever the display is, so one set
    // of sizes serves every resolution. Width follows the aspect ratio.
    static let designHeight: Double = 1440

    // MARK: - Entry point

    public static func render(
        _ snapshots: [UsageSnapshot],
        layout: WallpaperLayoutID,
        canvas: WallpaperCanvas,
        generatedAt: Date,
        history: [String: [Double]] = [:],
        timeZone: TimeZone = .current
    ) -> String {
        let model = TelemetryModel.build(
            snapshots: snapshots, history: history, now: generatedAt, timeZone: timeZone)
        return render(model, layout: layout, canvas: canvas)
    }

    /// Render an already-built model.
    ///
    /// Exposed because the app builds the same model for the menu bar and should not pay to
    /// build it twice, and because tests get to construct a model directly rather than
    /// reverse-engineering snapshots that produce one.
    public static func render(
        _ model: TelemetryModel,
        layout: WallpaperLayoutID,
        canvas: WallpaperCanvas
    ) -> String {
        let scale = canvas.height > 0 ? canvas.height / designHeight : 1
        let designWidth = scale > 0 ? canvas.width / scale : canvas.width

        let body: String
        switch resolve(layout, designWidth: designWidth) {
        case .ledger: body = LedgerRail.render(model, designHeight: designHeight)
        case .board: body = MissionBoard.render(model, designHeight: designHeight)
        case .card: body = CompactCard.render(model, designHeight: designHeight)
        }

        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(Format.svg(canvas.width))" \
            height="\(Format.svg(canvas.height))" \
            viewBox="0 0 \(Format.svg(canvas.width)) \(Format.svg(canvas.height))">\
            <g transform="scale(\(Format.svg(scale)))">\(body)</g></svg>
            """
    }

    @available(*, deprecated, message: "Use render(_:layout:canvas:generatedAt:)")
    public static func render(
        _ snapshots: [UsageSnapshot],
        density: WallpaperDensity,
        canvas: WallpaperCanvas,
        generatedAt: Date
    ) -> String {
        render(snapshots, layout: density.layout, canvas: canvas, generatedAt: generatedAt)
    }

    /// Fall back when the canvas cannot carry the requested layout.
    ///
    /// The board needs real width. Rather than squeezing four columns of tiles into a
    /// laptop and producing something unreadable, it becomes the rail — which is a different
    /// arrangement of exactly the same information, and legible at any width.
    static func resolve(_ layout: WallpaperLayoutID, designWidth: Double) -> WallpaperLayoutID {
        if layout == .board && designWidth < MissionBoard.minimumDesignWidth {
            return .ledger
        }
        return layout
    }
}
