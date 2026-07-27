import Foundation
import XCTest

@testable import ClaudrupleDesktop

final class WallpaperStateTests: XCTestCase {

    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudruple-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheRememberedOriginalSurvivesARoundTrip() throws {
        // This is the whole point of the file: after a restart we must still know what the
        // wallpaper was before we ever touched it.
        var state = WallpaperState()
        state["screen-1"] = .init(
            pristine: URL(fileURLWithPath: "/Users/x/Pictures/lake.jpg"),
            lastOutput: "desktop-b.png")
        try state.save(to: file)

        let reloaded = WallpaperState.load(from: file)
        XCTAssertEqual(reloaded["screen-1"].pristine?.path, "/Users/x/Pictures/lake.jpg")
        XCTAssertEqual(reloaded["screen-1"].lastOutput, "desktop-b.png")
    }

    func testAMissingFileIsAnEmptyStateRatherThanAFailure() {
        let state = WallpaperState.load(from: file)

        XCTAssertTrue(state.displays.isEmpty)
        XCTAssertNil(state["screen-1"].pristine, "an unknown display reads as blank")
    }

    func testACorruptFileIsAnEmptyStateRatherThanAFailure() throws {
        // Refusing to run because a cache entry is unreadable trades a recoverable problem
        // for an unrecoverable one.
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(WallpaperState.load(from: file).displays.isEmpty)
    }

    func testDisplaysAreTrackedIndependently() throws {
        // Each screen has its own wallpaper, so one remembered original cannot serve both.
        var state = WallpaperState()
        state["screen-1"] = .init(pristine: URL(fileURLWithPath: "/a.jpg"))
        state["screen-2"] = .init(pristine: URL(fileURLWithPath: "/b.jpg"))
        try state.save(to: file)

        let reloaded = WallpaperState.load(from: file)
        XCTAssertEqual(reloaded["screen-1"].pristine?.path, "/a.jpg")
        XCTAssertEqual(reloaded["screen-2"].pristine?.path, "/b.jpg")
    }
}
