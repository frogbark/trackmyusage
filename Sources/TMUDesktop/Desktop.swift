import Foundation
import TMURender

/// One display, in the terms the wallpaper pipeline needs.
public struct Display: Sendable, Equatable {
    /// Stable enough to key per-display state on for the length of a session.
    public let id: String
    public let name: String
    /// Backing pixels, not points — a wallpaper rendered at point size is soft on Retina.
    public let canvas: WallpaperCanvas

    public init(id: String, name: String, canvas: WallpaperCanvas) {
        self.id = id
        self.name = name
        self.canvas = canvas
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
