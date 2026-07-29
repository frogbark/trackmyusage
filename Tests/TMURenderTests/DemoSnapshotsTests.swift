import Foundation
import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMURender

/// The demo fixtures are shipped artefacts, not scratch data: they produce the images on
/// trackmyusage.dev. These tests pin the two properties the website depends on — that the
/// renders are reproducible, and that each case actually shows the state it is named after.
final class DemoSnapshotsTests: XCTestCase {

    /// Prevents: `check-generated.sh` failing on a clean tree, every day, forever.
    ///
    /// The committed SVGs are diffed against a fresh render. If anything in the pipeline
    /// reached for the wall clock, two runs a second apart would differ and the check would
    /// report staleness that no commit could fix.
    ///
    /// Note what this cannot see. Both renders happen in one process, so it agrees with
    /// itself about anything ambient — and `Format.time` reads `TimeZone.current`, which
    /// made the same frozen instant render 20:33 on a laptop and 03:33 on a UTC runner.
    /// This test passed on both. `generate-web.sh` pins `TZ=UTC` for that reason; a test
    /// cannot, because it would only be asserting the timezone it was already running in.
    func testRenderingTheSameCaseTwiceProducesIdenticalBytes() {
        for demo in DemoWallpaper.allCases {
            XCTAssertEqual(demo.svg(), demo.svg(), "\(demo.rawValue) is not reproducible")
        }
    }

    /// Prevents: the site showing two identical cards captioned "quiet" and "alert".
    ///
    /// Attention is derived from the readings, never set. If someone tunes `calm()` upward
    /// past the warn threshold the quiet card silently becomes the alert card, and the one
    /// image whose entire job is to demonstrate restraint stops demonstrating it.
    func testTheCalmFixtureIsBelowTheThresholdThatWakesTheCardUp() {
        let model = TelemetryModel.build(
            snapshots: DemoSnapshots.calm(), history: DemoSnapshots.history(),
            now: DemoSnapshots.generatedAt)
        XCTAssertEqual(model.attention, .quiet)
    }

    /// Prevents: the busy fixture drifting down until the alert card has nothing to lead with.
    func testTheBusyFixtureIsHotEnoughToRaiseTheAlertCard() {
        let model = TelemetryModel.build(
            snapshots: DemoSnapshots.busy(), history: DemoSnapshots.history(),
            now: DemoSnapshots.generatedAt)
        XCTAssertEqual(model.attention, .alert)
    }

    /// Prevents: shipping an empty or truncated SVG, which fails as a blank space on the
    /// page rather than as an error anyone would notice.
    func testEveryDemoCaseRendersACompleteDocumentAtTheRequestedCanvas() {
        let canvas = WallpaperCanvas(width: 2560, height: 1440)
        for demo in DemoWallpaper.allCases {
            let svg = demo.svg(canvas: canvas)
            XCTAssertTrue(svg.hasPrefix("<svg"), "\(demo.rawValue) is not an SVG document")
            XCTAssertTrue(svg.hasSuffix("</svg>"), "\(demo.rawValue) is truncated")
            XCTAssertTrue(
                svg.contains("viewBox=\"0 0 2560 1440\""),
                "\(demo.rawValue) did not honour the requested canvas")
        }
    }

    /// Prevents: the board case silently rendering as the rail on the website.
    ///
    /// `resolve` falls back when the canvas is too narrow for tiles. That is correct on a
    /// laptop and wrong on a page that captions the image "board", so the demo canvas has to
    /// stay wide enough to get the layout it asked for.
    func testTheBoardDemoIsWideEnoughToActuallyRenderAsABoard() {
        XCTAssertEqual(
            WallpaperSVG.resolve(.board, designWidth: 2560), .board,
            "the demo canvas would fall back to the rail")
    }
}
