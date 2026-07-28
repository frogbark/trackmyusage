#if canImport(AppKit)

import AppKit
import TMUProviders
import Foundation
import XCTest

@testable import TMURender

final class AppKitRasterizerTests: XCTestCase {

    private let canvas = WallpaperCanvas(width: 2560, height: 1440)
    private let now = Date(timeIntervalSince1970: 1_784_050_920)

    /// Two providers, so the panel's height is predictable and pixels can be sampled
    /// against a known rectangle.
    private var overlay: String {
        let snapshots = ["alpha", "beta"].map { name in
            UsageSnapshot(
                provider: name, account: nil, observedAt: now, status: .ok,
                metrics: [
                    Metric(
                        key: "usage", kind: .percentOfLimit, value: 40, limit: nil,
                        window: .rolling(3600), resetsAt: nil)
                ])
        }
        return WallpaperSVG.render(
            snapshots, density: .full, canvas: canvas, generatedAt: now)
    }

    // MARK: - Fixtures

    private func solidBackground(_ color: NSColor, size: CGSize) throws -> URL {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bg-\(width)x\(height)-\(color.description.hashValue).png")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Samples with a top-left origin, matching SVG coordinates.
    private func pixel(_ data: Data, x: Int, y: Int) throws -> NSColor {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        return try XCTUnwrap(rep.colorAt(x: x, y: y)).usingColorSpace(.deviceRGB)!
    }

    // MARK: - Composition

    func testTheCompositeIsTheCanvasSize() throws {
        let background = try solidBackground(.white, size: CGSize(width: 800, height: 600))
        let png = try AppKitRasterizer().compose(
            svg: overlay, over: background, canvas: canvas)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 2560)
        XCTAssertEqual(
            rep.pixelsHigh, 1440,
            "a background of a different size is scaled to the display, not left as-is")
    }

    func testTheBackgroundShowsThroughWhereTheOverlayDoesNotDraw() throws {
        // The point of compositing rather than replacing: everywhere the overlay is silent,
        // the photograph must be exactly what it was.
        let background = try solidBackground(
            .init(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1),
            size: CGSize(width: 2560, height: 1440))
        let png = try AppKitRasterizer().compose(
            svg: overlay, over: background, canvas: canvas)

        // Compared against the fixture decoded through the same path rather than against
        // literal components. Writing sRGB and reading back device RGB shifts every channel
        // by a few percent, which says something about colour management and nothing about
        // whether the photograph survived.
        let expected = try pixel(try Data(contentsOf: background), x: 2000, y: 200)
        let actual = try pixel(png, x: 2000, y: 200)

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01)
    }

    func testTheOverlayDarkensWhereItsPanelSits() throws {
        let background = try solidBackground(
            .init(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1),
            size: CGSize(width: 2560, height: 1440))
        let png = try AppKitRasterizer().compose(
            svg: overlay, over: background, canvas: canvas)

        // Inside the rail: x 72–472, vertically centred, so (200, 720) lands on the scrim.
        let scrim = try pixel(png, x: 200, y: 720)
        XCTAssertLessThan(
            scrim.brightnessComponent, 0.6,
            "the scrim has to actually darken, or nothing on it is legible")
    }

    func testWithoutABackgroundTheOverlayGetsItsOwnCanvasRatherThanTransparency() throws {
        // A transparent PNG set as a desktop background renders as plain black on some
        // window servers and as white on others. Neither is a design decision anyone made.
        let png = try AppKitRasterizer().compose(svg: overlay, over: nil, canvas: canvas)

        let corner = try pixel(png, x: 2400, y: 100)
        XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.01, "fully opaque everywhere")
    }

    func testAnUnreadableBackgroundIsReportedRatherThanSilentlyIgnored() {
        let missing = URL(fileURLWithPath: "/nope/not-here.png")

        XCTAssertThrowsError(
            try AppKitRasterizer().compose(svg: overlay, over: missing, canvas: canvas)
        ) { error in
            guard case RasterizerError.unreadableBackground = error else {
                return XCTFail("expected unreadableBackground, got \(error)")
            }
        }
    }

    func testMalformedSVGIsReportedRatherThanProducingABlankDesktop() {
        XCTAssertThrowsError(
            try AppKitRasterizer().compose(
                svg: "<svg><unclosed>", over: nil, canvas: canvas)
        ) { error in
            guard case RasterizerError.rasterizationFailed = error else {
                return XCTFail("expected rasterizationFailed, got \(error)")
            }
        }
    }
}

#endif
