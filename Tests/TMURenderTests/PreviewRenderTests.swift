#if canImport(AppKit)

import AppKit
import Foundation
import TMUProviders
import XCTest

@testable import TMURender

/// Writes a PNG per layout so a person can look at them.
///
/// Skipped unless `TMU_PREVIEW_DIR` is set, because it is not an assertion — it is the
/// step between "the invariants pass" and "the design is right", and those are different
/// questions. Geometry tests cannot tell you that a column is too narrow or that the
/// quiet card recedes too far; only looking can.
///
///     TMU_PREVIEW_DIR=/tmp/previews swift test --filter PreviewRender
///
/// The fixtures live in `DemoSnapshots` rather than here because the website renders the
/// same four cases through the same function. Two copies of this data would drift, and the
/// first symptom would be a site showing a layout the previews had never approved.
final class PreviewRenderTests: XCTestCase {

    func testWritePreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["TMU_PREVIEW_DIR"] else {
            throw XCTSkip("set TMU_PREVIEW_DIR to write preview images")
        }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)

        let canvas = WallpaperCanvas.default
        for demo in DemoWallpaper.allCases {
            let png = try AppKitRasterizer().compose(
                svg: demo.svg(canvas: canvas), over: nil, canvas: canvas)
            try png.write(to: root.appendingPathComponent("\(demo.rawValue).png"))
        }
    }
}

#endif
