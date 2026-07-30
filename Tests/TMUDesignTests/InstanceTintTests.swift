import XCTest

@testable import TMUDesign

/// Colour is being used as identity here, so the properties that matter are stability and
/// separation rather than anything aesthetic.
final class InstanceTintTests: XCTestCase {

    /// Prevents: badges changing colour between runs.
    ///
    /// The obvious implementation is `name.hashValue % palette.count`, and Swift seeds its
    /// hasher randomly per process — so the tint would differ on every launch and every
    /// machine, while passing any test that computed it twice in one process. This asserts
    /// the exact colours, so a change of algorithm has to be deliberate.
    func testTheSameNameAlwaysGetsTheSameTint() {
        XCTAssertEqual(InstanceTint.tint(for: "Work").value, InstanceTint.tint(for: "Work").value)
        // Pinned literals, computed independently from the FNV-1a definition rather than
        // read back out of this function: recomputing the expectation from the code under
        // test would agree with any implementation, including a randomly seeded one.
        XCTAssertEqual(InstanceTint.tint(for: "Work").value, "#4a8ef0")
        XCTAssertEqual(InstanceTint.tint(for: "Personal").value, "#8a9aa8")
        XCTAssertEqual(InstanceTint.tint(for: "Claude Two").value, "#c264e0")
    }

    /// Prevents: a digest that ignores part of the name, which would give two instances the
    /// same badge for no reason a user could see.
    func testNamesThatDifferAnywhereProduceDifferentDigests() {
        XCTAssertNotEqual(InstanceTint.digest("Work"), InstanceTint.digest("work"))
        XCTAssertNotEqual(InstanceTint.digest("Work"), InstanceTint.digest("Work "))
        XCTAssertNotEqual(InstanceTint.digest("Client A"), InstanceTint.digest("Client B"))
    }

    /// Prevents: the badge wearing a colour that means something else.
    ///
    /// `Ink.warn` and `Ink.over` mean "near its limit" on every other surface. An instance
    /// permanently badged amber would be making a claim about usage that it is not making.
    func testNoTintCollidesWithTheStatePalette() {
        let states = [Ink.warn.value, Ink.over.value, Ink.ok.value]
        for tint in InstanceTint.palette {
            XCTAssertFalse(states.contains(tint.value), "\(tint.value) is a state colour")
        }
    }

    /// Prevents: two palette entries close enough to be the same badge at 32 points.
    ///
    /// Crude on purpose — a full perceptual distance would be more accurate and harder to
    /// argue with when it fails. This catches the case that actually matters: someone adding
    /// a ninth colour a few values away from an existing one.
    func testPaletteColoursAreSeparated() {
        for (i, a) in InstanceTint.palette.enumerated() {
            for b in InstanceTint.palette[(i + 1)...] {
                let distance =
                    abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue)
                XCTAssertGreaterThan(
                    distance, 0.36, "\(a.value) and \(b.value) are too close to tell apart")
            }
        }
    }

    /// Prevents: an empty or whitespace name crashing the badge generator.
    func testTheInitialSurvivesNamesThatAreNotWords() {
        XCTAssertEqual(InstanceTint.initial(for: "Work"), "W")
        XCTAssertEqual(InstanceTint.initial(for: "  personal"), "P")
        XCTAssertEqual(InstanceTint.initial(for: "élan"), "É")
        XCTAssertEqual(InstanceTint.initial(for: ""), "?")
        XCTAssertEqual(InstanceTint.initial(for: "   "), "?")
    }

    /// Prevents: a tint index out of range for any name at all.
    func testEveryNameLandsInThePalette() {
        for name in ["", "a", "Work", "Claude Two", "🙂", String(repeating: "x", count: 500)] {
            XCTAssertTrue(
                InstanceTint.palette.contains { $0.value == InstanceTint.tint(for: name).value },
                "\(name) produced a tint outside the palette")
        }
    }
}
