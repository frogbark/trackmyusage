import Foundation

/// Turns the SVG overlay into a finished desktop image.
///
/// The seam between "what the wallpaper looks like", which is pure text and identical
/// everywhere, and "how pixels get made", which is the only part that needs a platform.
public protocol WallpaperRasterizer {
    /// Draws `svg` over `background`, scaled to `canvas`, and returns PNG data.
    ///
    /// A nil background means there is no pristine wallpaper to composite onto — the
    /// implementation supplies its own, rather than leaving transparency.
    func compose(svg: String, over background: URL?, canvas: WallpaperCanvas) throws -> Data
}

public enum RasterizerError: Error, Equatable, CustomStringConvertible {
    case unreadableBackground(String)
    case rasterizationFailed(String)
    case encodingFailed
    case unsupportedPlatform(String)

    public var description: String {
        switch self {
        case .unreadableBackground(let path):
            return "could not read the current wallpaper at \(path)"
        case .rasterizationFailed(let detail):
            return "could not rasterise the overlay: \(detail)"
        case .encodingFailed:
            return "could not encode the composed image as PNG"
        case .unsupportedPlatform(let detail):
            return "no rasteriser available on this platform: \(detail)"
        }
    }
}
