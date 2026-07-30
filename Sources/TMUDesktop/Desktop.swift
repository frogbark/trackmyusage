import Foundation
import TMURender

/// One display, in the terms the wallpaper pipeline needs.
public struct Display: Sendable, Equatable {
    /// Stable enough to key per-display state on for the length of a session.
    public let id: String
    public let name: String
    /// Backing pixels, not points — a wallpaper rendered at point size is soft on Retina.
    public let canvas: WallpaperCanvas
    /// Backing scale factor: 2 on Retina, 1 otherwise.
    ///
    /// Carried rather than discarded because `canvas` alone cannot say how large a display
    /// is in any sense a person would recognise. A 14-inch laptop is 3024×1964 pixels and a
    /// 27-inch 5K is 5120×2880; in points they are 1512×982 and 2560×1440, which is the
    /// difference automatic layout selection turns on. Rendering still uses pixels.
    public let scale: Double

    /// The display in points — how much interface it actually fits.
    public var points: WallpaperCanvas {
        guard scale > 0 else { return canvas }
        return WallpaperCanvas(width: canvas.width / scale, height: canvas.height / scale)
    }

    public init(id: String, name: String, canvas: WallpaperCanvas, scale: Double = 1) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.scale = scale
    }
}

/// Reading and writing the desktop background.
///
/// The only per-OS surface in the whole pipeline. Everything above it — snapshots, layout,
/// SVG — is identical everywhere, which is what keeps the platform-specific code down to
/// one call in each direction.
public protocol Desktop {
    func displays() throws -> [Display]
    func currentWallpaper(for display: Display) -> URL?
    func setWallpaper(_ url: URL, for display: Display) throws
}

public enum DesktopError: Error, Equatable, CustomStringConvertible {
    case noDisplays
    case unsupportedPlatform(String)
    case couldNotSet(String)

    public var description: String {
        switch self {
        case .noDisplays:
            return "no displays found"
        case .unsupportedPlatform(let detail):
            return "setting the wallpaper is not supported here: \(detail)"
        case .couldNotSet(let detail):
            return "could not set the wallpaper: \(detail)"
        }
    }
}

/// Picks the platform implementation.
public enum DesktopFactory {
    public static func current() throws -> Desktop {
        #if canImport(AppKit)
        return AppKitDesktop()
        #else
        throw DesktopError.unsupportedPlatform(
            "only macOS is implemented; Linux and Windows backends are still to come")
        #endif
    }
}
