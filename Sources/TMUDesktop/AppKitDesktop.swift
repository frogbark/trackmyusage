#if canImport(AppKit)

import AppKit
import TMURender
import Foundation

public struct AppKitDesktop: Desktop {

    public init() {}

    public func displays() throws -> [Display] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw DesktopError.noDisplays }

        return screens.enumerated().map { index, screen in
            let scale = screen.backingScaleFactor
            return Display(
                id: identifier(of: screen) ?? "screen-\(index)",
                name: screen.localizedName,
                canvas: WallpaperCanvas(
                    width: screen.frame.width * scale,
                    height: screen.frame.height * scale))
        }
    }

    public func currentWallpaper(for display: Display) -> URL? {
        screen(for: display).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    public func setWallpaper(_ url: URL, for display: Display) throws {
        guard let screen = screen(for: display) else {
            throw DesktopError.couldNotSet("display \(display.id) is no longer attached")
        }
        do {
            // .allowClipping keeps a wallpaper rendered at exactly the display's pixel
            // size from being letterboxed by a stale fill setting.
            try NSWorkspace.shared.setDesktopImageURL(
                url, for: screen,
                options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
        } catch {
            throw DesktopError.couldNotSet("\(error)")
        }
    }

    // MARK: -

    private func screen(for display: Display) -> NSScreen? {
        NSScreen.screens.first { identifier(of: $0) == display.id }
            ?? NSScreen.screens.first { $0.localizedName == display.name }
    }

    private func identifier(of screen: NSScreen) -> String? {
        (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)
            .map { "screen-\($0.uint32Value)" }
    }
}

#endif
