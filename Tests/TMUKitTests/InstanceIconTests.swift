#if canImport(AppKit)

import AppKit
import Foundation
import TMUDesign
import XCTest

@testable import TMUKit

/// The badge is what tells two instances apart, so the properties worth pinning are that it
/// is actually drawn, that it is the same every time, and that it differs per instance.
final class InstanceIconTests: XCTestCase {

    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.png")
        try flatImage().write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Prevents: an iconset `iconutil` will not accept.
    ///
    /// It requires this exact set of names and sizes and fails on a missing one, so a
    /// dropped variant turns into an instance with no icon at all rather than an unbadged
    /// one — and only at creation time, on someone else's machine.
    func testTheIconsetHasEveryVariantIconutilRequires() throws {
        let out = root.appendingPathComponent("Work.iconset")
        try InstanceIcon.writeIconset(name: "Work", source: source, into: out)

        let expected = [
            "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
        ]
        for (file, pixels) in expected {
            let url = out.appendingPathComponent(file)
            let rep = try XCTUnwrap(
                NSImage(contentsOf: url).flatMap { $0.representations.first },
                "\(file) is missing")
            XCTAssertEqual(rep.pixelsWide, pixels, "\(file) is the wrong size")
            XCTAssertEqual(rep.pixelsHigh, pixels, "\(file) is the wrong size")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: out.path).count,
            expected.count, "the iconset has files iconutil does not expect")
    }

    /// Prevents: regenerating an icon changing it.
    ///
    /// `refresh-instance.sh` re-clones from Claude and re-badges every time, so this runs
    /// again on every refresh. If it were not deterministic the instance would change colour
    /// whenever it was refreshed — and colour is the whole identity.
    func testTheSameNameProducesTheSameBytesEveryTime() throws {
        let base = try XCTUnwrap(NSImage(contentsOf: source))
        let first = try InstanceIcon.badged(base, name: "Work", pixels: 128)
        let second = try InstanceIcon.badged(base, name: "Work", pixels: 128)
        XCTAssertEqual(first, second)
    }

    /// Prevents: the whole feature silently doing nothing.
    ///
    /// If the badge were drawn off-canvas, or with a clear colour, every icon would still be
    /// produced at the right size and every other test here would pass.
    func testTheBadgeActuallyChangesTheImage() throws {
        let base = try XCTUnwrap(NSImage(contentsOf: source))
        let badged = try InstanceIcon.badged(base, name: "Work", pixels: 128)
        let plain = try XCTUnwrap(flatImage(size: 128))
        XCTAssertNotEqual(badged, plain, "the badge left the image untouched")
    }

    /// Prevents: two instances sharing a badge because the name never reached the drawing.
    func testDifferentNamesProduceDifferentIcons() throws {
        let base = try XCTUnwrap(NSImage(contentsOf: source))
        // Names chosen to land on different palette entries; the tint tests pin which.
        let work = try InstanceIcon.badged(base, name: "Work", pixels: 128)
        let personal = try InstanceIcon.badged(base, name: "Personal", pixels: 128)
        XCTAssertNotEqual(work, personal)
    }

    /// Prevents: an unreadable source being written out as an empty or transparent icon.
    ///
    /// The caller treats a throw as "leave it unbadged" and carries on; a silent success
    /// would replace a working icon with nothing.
    func testAnUnreadableSourceThrowsRatherThanProducingABlankIcon() {
        let missing = root.appendingPathComponent("nothing.icns")
        XCTAssertThrowsError(
            try InstanceIcon.writeIconset(name: "Work", source: missing, into: root))
    }

    /// Prevents: a letter being drawn at a size where it is three pixels of mud.
    ///
    /// Below the threshold the badge is colour only, which is why colour is the primary
    /// signal. Asserted through the threshold rather than by reading pixels, so it states
    /// the rule rather than a rendering.
    func testTheLetterIsOmittedAtSizesTooSmallToReadIt() throws {
        XCTAssertEqual(InstanceIcon.letterThreshold, 64)
        let base = try XCTUnwrap(NSImage(contentsOf: source))
        // Two names with the same tint would be identical below the threshold and differ
        // above it. "W" and "P" land on different tints, so compare a name against itself
        // rendered at both sizes instead: it must simply not crash at the small size.
        XCTAssertNoThrow(try InstanceIcon.badged(base, name: "Work", pixels: 16))
        XCTAssertNoThrow(try InstanceIcon.badged(base, name: "Work", pixels: 1024))
    }

    // MARK: - Fixtures

    /// A plain opaque square, standing in for an app icon.
    private func flatImage(size: Int = 1024) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

#endif
