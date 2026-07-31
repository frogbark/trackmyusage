import Foundation
import TMUProviders
import TMUTelemetry

/// The demo renders worth producing: one per layout, plus both faces of the card.
///
/// Named as a type rather than written out at each call site because two of them exist —
/// the preview PNGs a person eyeballs, and the SVGs the website ships — and a case added to
/// one list but not the other is a layout that goes to production having been looked at by
/// nobody.
public enum DemoWallpaper: String, CaseIterable, Sendable {
    case ledger
    case board
    /// The card with something hot: it grows, brightens and leads with the offender.
    case cardAlert = "card-alert"
    /// The same card when everything is under 80% and there is nothing to say.
    case cardQuiet = "card-quiet"

    public var layout: WallpaperLayoutID {
        switch self {
        case .ledger: return .ledger
        case .board: return .board
        case .cardAlert, .cardQuiet: return .card
        }
    }

    public var snapshots: [UsageSnapshot] {
        switch self {
        case .cardQuiet: return DemoSnapshots.calm()
        case .ledger, .board, .cardAlert: return DemoSnapshots.busy()
        }
    }

    /// Render this case at the given canvas, dated to the frozen demo instant.
    ///
    /// UTC, stated here rather than exported before running the generator. A frozen instant
    /// is only half of reproducibility: the panel draws a clock, so the zone it is read in
    /// is an input too, and leaving that to the machine is what made the committed images
    /// disagree with the ones CI produced.
    public func svg(canvas: WallpaperCanvas = .default) -> String {
        WallpaperSVG.render(
            snapshots, layout: layout, canvas: canvas,
            generatedAt: DemoSnapshots.generatedAt, history: DemoSnapshots.history(),
            timeZone: DemoSnapshots.timeZone)
    }
}
