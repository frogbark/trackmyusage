import XCTest

@testable import TMUKit

/// `tmud layout` decides what to do before it writes anything, and those rules live here
/// rather than in the executable so they can be asserted rather than tried.
final class LayoutAssignmentTests: XCTestCase {

    private let known: Set<String> = ["ledger", "board", "card"]

    /// Prevents: a typo being stored and silently ignored.
    ///
    /// An unknown name decodes fine and then loses to the default at render time, so the
    /// setting would look accepted and change nothing on screen — the worst of both.
    func testAnUnknownLayoutIsRejectedRatherThanStored() {
        XCTAssertEqual(
            LayoutAssignment.plan(target: "screen-1", choice: "hologram", known: known),
            .unknownLayout("hologram"))
        XCTAssertEqual(
            LayoutAssignment.plan(target: "--default", choice: "hologram", known: known),
            .unknownLayout("hologram"))
    }

    /// Prevents: a default of "default", which would fall back to itself.
    func testTheDefaultCannotBeTheClearingToken() {
        XCTAssertEqual(
            LayoutAssignment.plan(target: "--default", choice: "default", known: known),
            .defaultCannotBeClearing)
    }

    /// Prevents: clearing a display and setting it, or either being mistaken for the other.
    func testTheClearingTokenClearsADisplayWhileANameAssignsIt() {
        XCTAssertEqual(
            LayoutAssignment.plan(target: "screen-1", choice: "default", known: known),
            .clear(display: "screen-1"))
        XCTAssertEqual(
            LayoutAssignment.plan(target: "screen-1", choice: "card", known: known),
            .assign(display: "screen-1", layout: "card"))
    }

    func testTheDefaultIsSetByItsOwnTarget() {
        XCTAssertEqual(
            LayoutAssignment.plan(target: "--default", choice: "board", known: known),
            .setDefault("board"))
    }

    /// Prevents: a display literally named `--default` being unreachable, and more usefully,
    /// the two paths being told apart by anything vaguer than an exact match.
    func testOnlyTheExactDefaultTokenMeansTheDefault() {
        XCTAssertEqual(
            LayoutAssignment.plan(target: "--defaults", choice: "card", known: known),
            .assign(display: "--defaults", layout: "card"))
    }

    /// Prevents: the round trip through Settings disagreeing with the plan.
    ///
    /// Planning and applying are separate steps, so this checks the pair: assign then
    /// resolve, clear then resolve.
    func testAssigningThenResolvingAgreesWithWhatWasPlanned() {
        var settings = Settings(defaultLayout: "ledger")

        guard
            case .assign(let id, let layout) =
                LayoutAssignment.plan(target: "screen-1", choice: "card", known: known)
        else { return XCTFail("expected an assignment") }
        settings.layoutByDisplay[id] = layout
        XCTAssertEqual(settings.layout(for: "screen-1", known: known), "card")

        guard
            case .clear(let cleared) =
                LayoutAssignment.plan(target: "screen-1", choice: "default", known: known)
        else { return XCTFail("expected a clear") }
        settings.layoutByDisplay.removeValue(forKey: cleared)
        XCTAssertEqual(settings.layout(for: "screen-1", known: known), "ledger")
    }
}
