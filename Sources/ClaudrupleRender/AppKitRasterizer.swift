#if canImport(AppKit)

import AppKit
import Foundation
import ImageIO

/// Rasterises using AppKit, which needs no third-party dependency at all.
///
/// macOS reads SVG through `NSImage` directly, so bundling a Rust rasteriser — the obvious
/// plan for getting one renderer onto three platforms — turns out to be unnecessary here.
/// Linux and Windows still need one. This type is why that requirement never reaches the
/// platform the rest of this project already depends on.
public struct AppKitRasterizer: WallpaperRasterizer {

    public init() {}

    /// Drawn under everything when there is no wallpaper to composite onto.
    ///
    /// Deliberately not transparency: a PNG with an alpha channel set as a desktop
    /// background renders black on some window servers and white on others, and neither is
    /// a choice anyone made.
    private static let fallback = CGColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1)

    public func compose(
        svg: String, over background: URL?, canvas: WallpaperCanvas
    ) throws -> Data {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0 else {
            throw RasterizerError.rasterizationFailed("canvas is \(width)x\(height)")
        }

        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw RasterizerError.rasterizationFailed(
                "could not allocate a \(width)x\(height) bitmap")
        }

        let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(Self.fallback)
        context.fill(frame)

        // The overlay is parsed before anything is drawn. Failing late would leave a
        // background-only image that looks like a successful render with no data in it.
        let overlay = try parse(svg)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        if let background {
            guard let photo = NSImage(contentsOf: background), photo.isValid,
                photo.size.width > 0, photo.size.height > 0
            else {
                throw RasterizerError.unreadableBackground(background.path)
            }
            photo.draw(
                in: frame, from: crop(photo.size, filling: frame.size),
                operation: .copy, fraction: 1)
        }

        overlay.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)

        guard let image = context.makeImage() else { throw RasterizerError.encodingFailed }
        return try png(image)
    }

    // MARK: - Pieces

    private func parse(_ svg: String) throws -> NSImage {
        guard let image = NSImage(data: Data(svg.utf8)), image.isValid,
            image.size.width > 0, image.size.height > 0
        else {
            throw RasterizerError.rasterizationFailed("the overlay did not parse as SVG")
        }
        return image
    }

    /// The part of the photograph to show, so it fills the display without distorting.
    ///
    /// Stretching to fit is the tempting one-liner and it is visibly wrong the moment the
    /// wallpaper's aspect ratio differs from the screen's — which it does whenever someone
    /// plugs in a second monitor.
    private func crop(_ source: CGSize, filling target: CGSize) -> CGRect {
        let scale = max(target.width / source.width, target.height / source.height)
        guard scale.isFinite, scale > 0 else {
            return CGRect(origin: .zero, size: source)
        }
        let visible = CGSize(width: target.width / scale, height: target.height / scale)
        return CGRect(
            x: (source.width - visible.width) / 2,
            y: (source.height - visible.height) / 2,
            width: visible.width, height: visible.height)
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else { throw RasterizerError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RasterizerError.encodingFailed
        }
        return data as Data
    }
}

#endif
