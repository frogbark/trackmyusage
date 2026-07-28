import Foundation
import XCTest

@testable import TMURender

final class WallpaperOriginTests: XCTestCase {

    private let output = URL(fileURLWithPath: "/Users/x/Library/Caches/TrackMyUsage/wallpaper")
    private let photo = URL(fileURLWithPath: "/Users/x/Pictures/lake.jpg")

    /// Readability is injected so these stay pure path tests. `unreadable` names the files
    /// that are gone; everything else is assumed present.
    private func origin(
        current: URL?, remembered: URL?, unreadable: Set<URL> = []
    ) -> URL? {
        WallpaperOrigin.pristine(
            current: current, remembered: remembered, outputDirectory: output,
            isReadable: { !unreadable.contains($0) })
    }

    // MARK: - The feedback loop

    func testTheCurrentWallpaperIsUsedWhenItIsNotOurs() {
        let origin = origin(current: photo, remembered: nil)

        XCTAssertEqual(origin, photo)
    }

    func testOurOwnOutputIsNeverCompositedOnto() {
        // The whole failure mode: composite onto the last render and the overlay stacks on
        // itself every cycle until the desktop is a pile of scrims. Nothing errors — it
        // just gets progressively worse — so the guard has to be structural.
        let ours = output.appendingPathComponent("desktop-a.png")
        let origin = origin(current: ours, remembered: photo)

        XCTAssertEqual(origin, photo, "fall back to what the wallpaper was before we set it")
    }

    func testThereIsNoOriginWhenOurOutputIsCurrentAndNothingWasRemembered() {
        // Someone cleared the remembered path, or it is a fresh install that inherited our
        // own render. Reporting nothing lets the caller draw its own background rather than
        // silently compositing onto itself.
        let ours = output.appendingPathComponent("desktop-a.png")
        let origin = origin(current: ours, remembered: nil)

        XCTAssertNil(origin)
    }

    func testANestedPathInsideTheOutputDirectoryIsStillOurs() {
        let nested = output.appendingPathComponent("displays/2/desktop-a.png")
        let origin = origin(current: nested, remembered: photo)

        XCTAssertEqual(origin, photo)
    }

    func testADirectoryMerelySharingAPrefixIsNotOurs() {
        // "/…/TrackMyUsage/wallpaper-backups" begins with the output path as a *string* but
        // is a different directory. Comparing path components rather than characters is
        // what stops a real photo from being mistaken for our own output and discarded.
        let neighbour = URL(
            fileURLWithPath: "/Users/x/Library/Caches/TrackMyUsage/wallpaper-backups/lake.jpg")
        let origin = origin(current: neighbour, remembered: photo)

        XCTAssertEqual(origin, neighbour, "a prefix match is not a containment match")
    }

    func testRelativeSegmentsAreResolvedBeforeComparing() {
        let sneaky = URL(
            fileURLWithPath: "/Users/x/Library/Caches/TrackMyUsage/wallpaper/../wallpaper/d.png")
        let origin = origin(current: sneaky, remembered: photo)

        XCTAssertEqual(origin, photo, "it resolves into our directory, so it is ours")
    }

    // MARK: - Missing inputs

    func testAnUnreadableCurrentWallpaperFallsBackToWhatWasRemembered() {
        let origin = origin(current: nil, remembered: photo)

        XCTAssertEqual(origin, photo)
    }

    func testThereIsNoOriginWhenNothingIsKnown() {
        let origin = origin(current: nil, remembered: nil)

        XCTAssertNil(origin)
    }

    func testAWallpaperPathThatNoLongerExistsIsSkipped() {
        // Found on a real machine: macOS reported a wallpaper inside a third-party app's
        // container that the app had since deleted. The path is returned happily, the file
        // is gone, and treating that as fatal means the daemon dies because someone else
        // tidied up their cache.
        let stale = URL(fileURLWithPath: "/Users/x/Library/Containers/com.example.app/gone.png")
        let result = origin(current: stale, remembered: photo, unreadable: [stale])

        XCTAssertEqual(result, photo, "fall back rather than fail")
    }

    func testAnUnreadableRememberedWallpaperIsAlsoSkipped() {
        // The remembered original can rot the same way — the user deleted the photo months
        // ago. Reporting nothing lets the caller draw its own background.
        let stale = URL(fileURLWithPath: "/Users/x/Library/Containers/com.example.app/gone.png")
        let result = origin(
            current: stale, remembered: photo, unreadable: [stale, photo])

        XCTAssertNil(result)
    }

    // MARK: - Alternating output

    func testConsecutiveRendersAlternateFilenames() {
        // macOS will not reload a wallpaper whose URL has not changed, so writing to one
        // path leaves the desktop showing a stale image even though the file updated.
        let first = WallpaperOrigin.outputName(previous: nil)
        let second = WallpaperOrigin.outputName(previous: first)
        let third = WallpaperOrigin.outputName(previous: second)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(third, first, "two names are enough to guarantee a change")
    }
}
