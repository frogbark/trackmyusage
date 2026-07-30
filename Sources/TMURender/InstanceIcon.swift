#if canImport(AppKit)

import AppKit
import Foundation
import TMUDesign

/// Claude's own icon with a coloured badge, so instances can be told apart in the Dock.
///
/// The badge is drawn over a copy of the icon already inside the clone, on the machine that
/// made the clone. Nothing is redistributed and the original bundle is never touched — the
/// same footing as the rest of `create-instance.sh`, which stamps a plist and compiles a
/// shim into a local copy.
///
/// Writes an `.iconset` directory rather than an `.icns` because `iconutil` is the only
/// supported way to produce the latter, and it is one shell line away in the script that
/// calls this.
public enum InstanceIcon {

    /// The sizes an `.iconset` must contain, as (point size, scale).
    ///
    /// Both scales of the small sizes matter more than they look: the Dock draws a large
    /// icon, but the app switcher, Finder columns and the "Force Quit" list all draw small
    /// ones, and an initial that is legible at 512 is a smudge at 16.
    static let variants: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    /// Below this pixel size the badge is a plain disc.
    ///
    /// A letter inside a disc that is 6 pixels across is noise that reads as a rendering
    /// fault. Colour still carries the identity there, which is why colour is the primary
    /// signal and the initial only ever a confirmation.
    static let letterThreshold = 64

    public enum IconError: Error, CustomStringConvertible {
        case unreadableSource(String)
        case drawFailed(Int)

        public var description: String {
            switch self {
            case .unreadableSource(let path): return "could not read an icon at \(path)"
            case .drawFailed(let pixels): return "could not render the \(pixels)px icon"
            }
        }
    }

    /// Write a full iconset for `name`, badged over `source`.
    public static func writeIconset(
        name: String, source: URL, into directory: URL
    ) throws {
        guard let base = NSImage(contentsOf: source), base.isValid else {
            throw IconError.unreadableSource(source.path)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        for variant in variants {
            let pixels = variant.points * variant.scale
            let png = try badged(base, name: name, pixels: pixels)
            let suffix = variant.scale == 2 ? "@2x" : ""
            let file = "icon_\(variant.points)x\(variant.points)\(suffix).png"
            try png.write(to: directory.appendingPathComponent(file))
        }
    }

    /// One size, as PNG data.
    static func badged(_ base: NSImage, name: String, pixels: Int) throws -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw IconError.drawFailed(pixels) }

        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw IconError.drawFailed(pixels)
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let side = CGFloat(pixels)
        let full = NSRect(x: 0, y: 0, width: side, height: side)
        base.draw(in: full, from: .zero, operation: .copy, fraction: 1)

        draw(badge: name, in: full, pixels: pixels)

        context.flushGraphics()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw IconError.drawFailed(pixels)
        }
        return data
    }

    private static func draw(badge name: String, in full: NSRect, pixels: Int) {
        let side = full.width
        // Bottom-right, which is where macOS itself puts badges and so where the eye already
        // looks. Large enough to read at 32 points without covering the artwork it sits on.
        let diameter = side * 0.42
        let margin = side * 0.03
        let circle = NSRect(
            x: full.maxX - diameter - margin, y: full.minY + margin,
            width: diameter, height: diameter)

        // A dark ring first, so the badge separates from whatever colour it lands on. Drawn
        // as a larger filled circle rather than a stroke: a stroke straddles the path and
        // loses half its width to antialiasing at 16 pixels.
        let ringWidth = max(1, side * 0.022)
        NSColor(calibratedWhite: 0.04, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: -ringWidth, dy: -ringWidth)).fill()

        let tint = InstanceTint.tint(for: name)
        NSColor(
            calibratedRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1
        ).setFill()
        NSBezierPath(ovalIn: circle).fill()

        guard pixels >= letterThreshold else { return }

        let letter = InstanceTint.initial(for: name)
        let size = diameter * 0.62
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            // Near-black rather than white: every palette entry is a mid-tone, and dark text
            // holds contrast across all eight where white only holds it on some.
            .foregroundColor: NSColor(calibratedWhite: 0.06, alpha: 0.92),
        ]
        let text = NSAttributedString(string: letter, attributes: attributes)
        let bounds = text.size()
        // Centred on the glyph's own box. Using the circle's centre directly sits the letter
        // low, because a capital's bounding box carries descender space it does not use.
        text.draw(
            at: NSPoint(
                x: circle.midX - bounds.width / 2,
                y: circle.midY - bounds.height / 2))
    }
}

#endif
