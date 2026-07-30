import Foundation
import XCTest

@testable import TMURender

/// Choosing a layout from the display.
///
/// The cases are real hardware rather than invented numbers, because the whole rule turns on
/// a distinction — points against pixels — that only bites on machines that actually exist.
final class LayoutFitTests: XCTestCase {

    /// Design width is the canvas normalised to the renderer's 1440-unit design height,
    /// which is what the layouts are laid out against.
    private func designWidth(_ canvas: WallpaperCanvas) -> Double {
        canvas.height > 0 ? canvas.width / (canvas.height / 1440) : canvas.width
    }

    private func fit(pixels: (Double, Double), scale: Double) -> WallpaperLayoutID {
        let canvas = WallpaperCanvas(width: pixels.0, height: pixels.1)
        let points = WallpaperCanvas(width: pixels.0 / scale, height: pixels.1 / scale)
        return LayoutFit.layout(points: points, designWidth: designWidth(canvas))
    }

    /// Prevents: the rule being written against pixels.
    ///
    /// This is the case the whole design turns on. A 14-inch MacBook is 3024×1964 and a
    /// 27-inch 5K is 5120×2880 — by pixel count the laptop is just a slightly smaller
    /// monitor, and a pixel-based rule gives them the same layout. In points they are
    /// 1512×982 and 2560×1440, and they want different ones.
    func testALaptopAndADesktopAreToldApartDespiteSimilarResolutions() {
        XCTAssertEqual(fit(pixels: (3024, 1964), scale: 2), .card, "14-inch MacBook Pro")
        XCTAssertEqual(fit(pixels: (5120, 2880), scale: 2), .ledger, "27-inch 5K")
    }

    /// Prevents: a non-Retina monitor being mistaken for a laptop.
    ///
    /// A 1080p display is 1920×1080 pixels at scale 1, so its point height is 1080. Dividing
    /// by the wrong scale, or not dividing at all, puts it in the wrong bucket.
    func testAnUnscaledMonitorIsNotTreatedAsALaptop() {
        XCTAssertEqual(fit(pixels: (1920, 1080), scale: 1), .ledger, "24-inch 1080p")
    }

    /// Pins the case the rule cannot actually decide, so the choice stays deliberate.
    ///
    /// A 16-inch MacBook is 1080 points tall and so is a 24-inch 1080p monitor — identical,
    /// because they fit identical amounts of interface. The threshold puts both on the rail,
    /// which is the recoverable error. This exists so that changing it is a decision someone
    /// makes rather than a side effect of moving a number.
    func testTheOneCaseTheRuleCannotSeparateFallsTowardsTheRail() {
        XCTAssertEqual(fit(pixels: (3456, 2160), scale: 2), .ledger, "16-inch MacBook Pro")
        XCTAssertEqual(fit(pixels: (1920, 1080), scale: 1), .ledger, "24-inch 1080p")
    }

    /// Prevents: every widescreen desktop getting the board.
    ///
    /// 16:9 is 1.78 and ordinary. The board is for displays wide enough that reading a
    /// column down one edge is the wrong shape, which starts around 2.0.
    func testAnOrdinaryWidescreenGetsTheRailAndAnUltrawideGetsTheBoard() {
        XCTAssertEqual(fit(pixels: (2560, 1440), scale: 1), .ledger, "16:9 at 1.78")
        XCTAssertEqual(fit(pixels: (6400, 2700), scale: 2), .board, "ultrawide at 2.37")
        XCTAssertEqual(fit(pixels: (3440, 1440), scale: 1), .board, "34-inch at 2.39")
    }

    /// Prevents: a laptop being handed the board because it happens to be wide.
    ///
    /// Height is checked first on purpose. A 16:9 laptop is not wide enough to trigger this,
    /// but the ordering is what guarantees no small display ever gets tiles — the thing
    /// least likely to survive being shrunk.
    func testASmallDisplayGetsTheCardWhateverItsShape() {
        XCTAssertEqual(fit(pixels: (2560, 1000), scale: 2), .card, "short and wide")
        XCTAssertEqual(fit(pixels: (1512, 982), scale: 1), .card, "small and unscaled")
    }

    /// Prevents: the board being chosen at a width where its own renderer refuses it.
    ///
    /// `WallpaperSVG.resolve` falls back to the rail below `MissionBoard.minimumDesignWidth`.
    /// Picking the board under that would produce a caption saying board and a rail on
    /// screen — the two would disagree, and the fallback would hide the mistake.
    func testTheBoardIsNeverChosenWhereResolveWouldRefuseIt() {
        for (w, h, scale) in [
            (6400.0, 2700.0, 2.0), (3440.0, 1440.0, 1.0), (2560.0, 1440.0, 1.0),
            (3024.0, 1964.0, 2.0), (1920.0, 1080.0, 1.0), (5120.0, 2880.0, 2.0),
        ] {
            let canvas = WallpaperCanvas(width: w, height: h)
            let chosen = fit(pixels: (w, h), scale: scale)
            XCTAssertEqual(
                WallpaperSVG.resolve(chosen, designWidth: designWidth(canvas)), chosen,
                "\(Int(w))x\(Int(h))@\(scale)x chose \(chosen) and would render as something else")
        }
    }

    /// Prevents: a display reported as zero-sized taking down the whole render.
    ///
    /// Nothing should produce one, which is exactly why it would not be noticed until it
    /// happened while enumerating screens.
    func testADegenerateDisplayGetsTheDefaultRatherThanDividingByZero() {
        XCTAssertEqual(
            LayoutFit.layout(points: WallpaperCanvas(width: 0, height: 0), designWidth: 0),
            .ledger)
        XCTAssertEqual(
            LayoutFit.layout(points: WallpaperCanvas(width: 2560, height: 0), designWidth: 2560),
            .ledger)
    }
}
