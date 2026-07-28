import Foundation
import XCTest

@testable import TMUDesign

/// The mark is geometry rather than a file, and this is what that buys.
///
/// An exported PNG is something a person has to remember to look at; bar heights and ratios
/// are things a test can assert. Five renderings of a logo drift apart the moment they are
/// five separate exports, so the one definition is checked rather than trusted.
final class BrandMarkTests: XCTestCase {

    func testTheBarsAscendInTheDocumentedRatio() {
        XCTAssertEqual(
            BrandMark.barHeights, [17, 31, 47],
            "the ascent is the mark — three rising bars read as a meter before they read as "
                + "a logo, which is the whole idea")
    }

    /// The third bar is what makes the glyph useful at 16pt in a menu bar: it can say
    /// "something is running hot" where nothing else at that size could.
    func testOnlyTheLastBarCarriesTheWarnColour() {
        XCTAssertEqual(BrandMark.ink(forBar: 0), Ink.ok)
        XCTAssertEqual(BrandMark.ink(forBar: 1), Ink.ok)
        XCTAssertEqual(BrandMark.ink(forBar: 2), Ink.warn)
    }

    func testTheMarkScalesLinearlyRatherThanDrifting() throws {
        let small = try widths(in: BrandMark.svg(size: 84))
        let large = try widths(in: BrandMark.svg(size: 168))

        XCTAssertEqual(small.count, large.count)
        for (a, b) in zip(small, large) {
            XCTAssertEqual(b, a * 2, accuracy: 0.01, "a 2x mark must be exactly twice as wide")
        }
    }

    /// macOS does not mask app icons, so the generator has to draw the rounded tile itself —
    /// and the radius has to be proportional, or the shape changes between 16pt and 1024.
    func testTheTileCornerStaysProportional() throws {
        for size in [64.0, 512.0, 1024.0] {
            let svg = BrandMark.svg(size: size)
            let radius = try XCTUnwrap(
                firstAttribute("rx", in: svg).map(Double.init) ?? nil)
            XCTAssertEqual(radius / size, BrandMark.tileRadiusRatio, accuracy: 0.001)
        }
    }

    func testTheTileCanBeOmittedForSurfacesThatHaveTheirOwn() {
        XCTAssertFalse(
            BrandMark.svg(size: 96, tile: false).contains("linearGradient"),
            "the website nav puts the bars on its own background")
        XCTAssertTrue(BrandMark.svg(size: 96, tile: true).contains("linearGradient"))
    }

    func testTheOutputIsAWellFormedDocument() {
        for size in [16.0, 32.0, 64.0, 512.0] {
            XCTAssertTrue(
                XMLParser(data: Data(BrandMark.svg(size: size).utf8)).parse(),
                "\(size)pt mark did not parse")
        }
    }

    /// A comma decimal separator is invalid in an SVG attribute, and would produce a mark
    /// that renders on the author's machine and not on a reviewer's.
    func testNumbersAreLocaleFree() {
        XCTAssertFalse(BrandMark.svg(size: 84.5).contains(","))
    }

    // MARK: -

    private func widths(in svg: String) throws -> [Double] {
        svg.components(separatedBy: "<rect").dropFirst().compactMap {
            firstAttribute("width", in: $0).flatMap(Double.init)
        }
    }

    private func firstAttribute(_ name: String, in svg: String) -> String? {
        guard let start = svg.range(of: " \(name)=\""),
            let end = svg[start.upperBound...].range(of: "\"")
        else { return nil }
        return String(svg[start.upperBound..<end.lowerBound])
    }
}
