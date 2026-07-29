#if canImport(AppKit)

import AppKit
import SwiftUI
import TMUDesign
import XCTest

@testable import TMUAppCore

/// Rasterises the glyph and looks at the pixels.
///
/// This exists because the glyph shipped broken twice, in two different ways, and neither
/// was visible to any other kind of test. First it drew with `Canvas`, which renders
/// nothing inside a `MenuBarExtra` label and reports nothing about it. Then it drew at
/// `height / designTile`, scaling from the app icon's 84pt tile rather than the 47pt
/// tallest bar — so a "16pt" glyph came out 9pt tall and 8.6pt wide, present but
/// unreadable on a status bar.
///
/// Both compiled, laid out and passed every assertion in the suite. Only counting lit
/// pixels catches "drew nothing" and "drew a smudge".
@MainActor
final class MarkGlyphTests: XCTestCase {

    /// Non-transparent pixels, and the bounding box they occupy.
    private func rasterise(_ view: some View, scale: CGFloat = 2)
        -> (lit: Int, width: Int, height: Int, bitmap: NSBitmapImageRep)?
    {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)

        var lit = 0
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.1
                else { continue }
                lit += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard lit > 0 else { return (0, 0, 0, bitmap) }
        return (lit, maxX - minX + 1, maxY - minY + 1, bitmap)
    }

    func testTheGlyphActuallyDrawsSomething() throws {
        let result = try XCTUnwrap(rasterise(MarkGlyph(peak: .ok)))
        XCTAssertGreaterThan(
            result.lit, 0,
            """
            The mark rendered as nothing. This is exactly what `Canvas` did inside a \
            MenuBarExtra label: compiled, laid out, drew no pixels, said nothing.
            """)
    }

    /// A menu bar glyph asked for 16pt should be 16pt, not a little over half of it.
    func testTheGlyphFillsTheHeightItWasAskedFor() throws {
        let scale: CGFloat = 2
        let result = try XCTUnwrap(rasterise(MarkGlyph(peak: .ok, height: 16), scale: scale))

        XCTAssertEqual(
            CGFloat(result.height) / scale, 16, accuracy: 1.5,
            "the tallest bar should reach the requested height")
        // 3 bars of 11 + 2 gaps of 6, scaled by 16/47 ≈ 15.3pt.
        XCTAssertEqual(
            CGFloat(result.width) / scale, 15.3, accuracy: 2,
            "and the mark should be about as wide as it is tall, not a sliver")
    }

    /// The third bar is the whole point: it can say "something is running hot" at 16
    /// points, where nothing else that size could.
    func testOnlyTheThirdBarChangesColourWithState() throws {
        let calm = try XCTUnwrap(rasterise(MarkGlyph(peak: .ok, height: 16)))
        let hot = try XCTUnwrap(rasterise(MarkGlyph(peak: .over, height: 16)))

        XCTAssertEqual(
            calm.width, hot.width, "state must not change the mark's geometry")
        XCTAssertNotEqual(
            colours(in: calm.bitmap), colours(in: hot.bitmap),
            "an over-limit reading has to look different from a calm one")
    }

    func testStaleFadesTheWholeMark() throws {
        let fresh = try XCTUnwrap(rasterise(MarkGlyph(peak: .ok, height: 16)))
        let stale = try XCTUnwrap(
            rasterise(MarkGlyph(peak: .ok, isStale: true, height: 16)))

        XCTAssertEqual(fresh.width, stale.width, "fading must not resize anything")
        XCTAssertLessThan(
            meanAlpha(stale.bitmap), meanAlpha(fresh.bitmap),
            "a stale reading should recede, matching the `?` beside it")
    }

    // MARK: -

    private func colours(in bitmap: NSBitmapImageRep) -> Set<String> {
        var found: Set<String> = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.9 else {
                    continue
                }
                found.insert(
                    String(
                        format: "%.1f,%.1f,%.1f", c.redComponent, c.greenComponent,
                        c.blueComponent))
            }
        }
        return found
    }

    private func meanAlpha(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.1 else {
                    continue
                }
                total += c.alphaComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Every bar has to be *visible*, not merely present.
    ///
    /// The alpha tests above count any non-transparent pixel, and opaque black has an
    /// alpha of 1 — so a bar drawn in the background's own colour passes them while being
    /// invisible. This checks contrast instead.
    ///
    /// Read the limit honestly: it does **not** reproduce the menu bar. `ImageRenderer`
    /// with an explicit dark `colorScheme` resolves `Color.primary` to white, so the
    /// version of this glyph that shipped with an invisible mark passes this test too.
    /// Whatever a `MenuBarExtra` label does to its content, it is not this, and no test
    /// here has caught it — the two glyph bugs so far were both found by looking at a
    /// screenshot. This guards the ordinary case; the menu bar still needs an eye.
    func testEveryBarContrastsWithADarkMenuBar() throws {
        let onDark =
            MarkGlyph(peak: .ok, height: 16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: onDark)
        renderer.scale = 4
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

        // Sample the bottom row, where all three bars are present, and count runs that
        // are clearly lighter than the background.
        let row = bitmap.pixelsHigh - 2
        var runs = 0
        var inRun = false
        for x in 0..<bitmap.pixelsWide {
            let bright = (bitmap.colorAt(x: x, y: row)?.brightnessComponent ?? 0) > 0.4
            if bright && !inRun { runs += 1 }
            inRun = bright
        }
        XCTAssertEqual(
            runs, 3,
            """
            Expected three visible bars against a dark background, saw \(runs). A bar \
            that renders in a colour matching the menu bar is not a bar.
            """)
    }

    /// The menu bar gets a bitmap, so the bitmap has to exist and have the right shape.
    ///
    /// This is the path the status item actually uses. The live view is only a source for it
    /// — `MenuBarExtra` will not draw shapes, so `body` being correct proves nothing about
    /// what appears on screen.
    func testTheMenuBarBitmapIsProducedAtTheRightSize() throws {
        let glyph = MarkGlyph(peak: .warn, height: 16)
        let image = try XCTUnwrap(glyph.nsImage(), "the pill has nothing to draw")

        XCTAssertEqual(image.size.height, 16, accuracy: 0.5)
        XCTAssertEqual(image.size.width, glyph.width, accuracy: 0.5)
        XCTAssertFalse(
            image.isTemplate,
            "a template is monochrome, and the third bar has to be able to turn amber")
        // Pixel density is deliberately not asserted. `ImageRenderer.scale` is honoured on a
        // machine with a display and ignored on a headless CI runner, so any threshold here
        // tests which machine ran the suite rather than anything the code decides. It was
        // written twice — once as "> width", once as ">= 1.5x" — and both times it failed on
        // CI for a reason no change to this file could fix.
        XCTAssertGreaterThan(
            image.representations.first?.pixelsWide ?? 0, 0, "the bitmap has no pixels")
    }

    /// Writes the pill as the menu bar composes it, so a person can look at it.
    /// Skipped unless TMU_GLYPH_DIR is set.
    func testWritePreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["TMU_GLYPH_DIR"] else {
            throw XCTSkip("set TMU_GLYPH_DIR to write a preview")
        }
        let pill = HStack(spacing: 4) {
            MarkGlyph(peak: .warn, height: 16)
            Text("2% · 20%").monospacedDigit().font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: pill)
        renderer.scale = 8
        let cg = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pill.png"))
    }
}

#endif
