import Foundation
import TMUDesign
import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMURender

/// Rules every layout has to obey, checked against every layout.
///
/// The alternative was golden files per layout per attention state per fixture, which is a
/// maintenance tax that teaches people to re-record without reading the diff. These are
/// properties instead: they do not move when a padding value changes, and each one names a
/// specific way a desktop gets ruined.
final class LayoutInvariantsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)
    private let canvas = WallpaperCanvas(width: 2560, height: 1440)

    /// Every combination worth checking: each layout, in both attention states, at the
    /// counts that actually occur — nothing, one account, four services (today), seventeen
    /// (the intended set).
    private var matrix: [(name: String, layout: WallpaperLayoutID, snapshots: [UsageSnapshot])] {
        var cases: [(String, WallpaperLayoutID, [UsageSnapshot])] = []
        for layout in WallpaperLayoutID.allCases {
            cases.append(("\(layout.rawValue)/empty", layout, []))
            cases.append(("\(layout.rawValue)/quiet", layout, fixture(count: 4, peak: 40)))
            cases.append(("\(layout.rawValue)/alert", layout, fixture(count: 4, peak: 96)))
            cases.append(("\(layout.rawValue)/full", layout, fixture(count: 17, peak: 104)))
            cases.append(("\(layout.rawValue)/nodata", layout, [unavailable("sentry")]))
        }
        return cases
    }

    // MARK: - Invariants

    func testEveryLayoutProducesAWellFormedDocument() {
        for entry in matrix {
            let svg = render(entry)
            XCTAssertTrue(
                XMLParser(data: Data(svg.utf8)).parse(),
                "\(entry.name) produced a document that will not parse — which reaches the "
                    + "user as a blank desktop, not as an error")
        }
    }

    /// Desktop icons must stay visible. Which edge that protects depends on the shape of the
    /// layout, and conflating the two would have forced the board to be something it is not.
    ///
    /// The rail and the card are left-anchored panels: icons stack down the right, so the
    /// rule is horizontal. The board is a bottom strip spanning most of the width — the
    /// design puts it at x=96 with a width of 1560, which reaches past any sensible vertical
    /// line — so for it the rule is that the upper two-thirds stays clear instead.
    func testTheLayoutLeavesRoomForDesktopIcons() {
        let rightEdge = 2560.0 * 0.55
        for entry in matrix {
            let svg = render(entry)
            switch entry.layout {
            case .ledger, .card:
                for x in xCoordinates(in: svg) {
                    XCTAssertLessThan(
                        x, rightEdge,
                        "\(entry.name) drew at x=\(x), past the \(Int(rightEdge))pt line "
                            + "that keeps the user's desktop icons visible")
                }
            case .board:
                // Only the outermost group is an absolute position; everything inside it is
                // relative to that anchor, so where the strip starts is the whole question.
                guard let anchor = yOrigins(in: svg).first else { continue }
                XCTAssertGreaterThan(
                    anchor, 1440.0 * 0.55,
                    "\(entry.name) anchored at y=\(anchor); the board is a bottom strip and "
                        + "must leave the upper desktop, where icons live, alone")
            }
        }
    }

    func testNoRectangleHasANegativeDimension() {
        for entry in matrix {
            let svg = render(entry)
            for value in attributes("width", in: svg) + attributes("height", in: svg) {
                XCTAssertGreaterThanOrEqual(
                    value, 0,
                    "\(entry.name) emitted a negative dimension, which most rasterisers "
                        + "silently drop and one draws inverted")
            }
        }
    }

    /// The number is never clamped — 104% reads as 104% — but the rectangle must be, or an
    /// overflowing fill paints straight over the label beside it.
    func testAFillNeverOutgrowsItsTrack() {
        for entry in matrix {
            let svg = render(entry)
            let tracks = widths(ofClass: "track", in: svg)
            let fills = widths(ofClass: "fill", in: svg)
            guard let widest = tracks.max(), let biggest = fills.max() else { continue }
            XCTAssertLessThanOrEqual(biggest, widest, "\(entry.name): fill exceeded its track")
        }
    }

    /// The daemon re-renders on a timer and compares. A layout that is not a pure function of
    /// its inputs would rewrite the desktop every five minutes for no reason.
    func testRenderingTheSameModelTwiceIsIdentical() {
        for entry in matrix {
            XCTAssertEqual(render(entry), render(entry), "\(entry.name) is not deterministic")
        }
    }

    /// Absence is stated, never drawn as zero. A provider that failed must say so in words.
    func testAFailedProviderIsNamedRatherThanDrawnAsEmpty() {
        for layout in WallpaperLayoutID.allCases {
            let svg = WallpaperSVG.render(
                [unavailable("sentry"), snapshot("github", 96)],
                layout: layout, canvas: canvas, generatedAt: now)
            XCTAssertTrue(
                svg.contains("no data"),
                "\(layout.rawValue) drew a failed provider without saying it had no reading")
            XCTAssertTrue(
                svg.contains("nodata"),
                "\(layout.rawValue) lost the structural marker tests rely on")
        }
    }

    /// The board needs real width. Squeezing four columns of tiles onto a laptop produces
    /// something unreadable, so it becomes the rail — the same information, legible anywhere.
    func testTheBoardFallsBackToTheRailOnANarrowDisplay() {
        XCTAssertEqual(
            WallpaperSVG.resolve(.board, designWidth: 1600), .ledger,
            "a 16:10 laptop cannot carry the board")
        XCTAssertEqual(WallpaperSVG.resolve(.board, designWidth: 2560), .board)
        XCTAssertEqual(
            WallpaperSVG.resolve(.ledger, designWidth: 800), .ledger,
            "the rail is legible at any width and must never be substituted")
    }

    // MARK: - Helpers

    private func render(
        _ entry: (name: String, layout: WallpaperLayoutID, snapshots: [UsageSnapshot])
    )
        -> String
    {
        WallpaperSVG.render(
            entry.snapshots, layout: entry.layout, canvas: canvas, generatedAt: now)
    }

    private func fixture(count: Int, peak: Double) -> [UsageSnapshot] {
        var out = [
            snapshot("claude", peak * 0.6, account: "Claude"),
            snapshot("claude", peak, account: "Claude Two"),
        ]
        for index in 1...count {
            out.append(snapshot("service\(index)", Double(index) / Double(count) * peak))
        }
        return out
    }

    private func snapshot(_ provider: String, _ utilization: Double, account: String? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            provider: provider, account: account, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "usage", kind: .percentOfLimit, value: utilization, limit: nil,
                    window: .rolling(3600), resetsAt: nil, label: "5-hour")
            ])
    }

    private func unavailable(_ provider: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: nil, observedAt: now,
            status: .unavailable("no public usage API"), metrics: [])
    }

    /// Absolute x of every mark, resolving the one level of `translate` the layouts use.
    private func xCoordinates(in svg: String) -> [Double] {
        var out: [Double] = []
        var offset = 0.0
        // Layouts emit `<g transform="translate(x,y)">` for each panel, then place marks
        // relative to it; tracking the most recent translate is enough to get absolute
        // positions without a full SVG parser.
        let scanner = svg.components(separatedBy: "<")
        for element in scanner {
            if element.hasPrefix("g transform=\"translate("),
                let inner = element.slice(from: "translate(", to: ")"),
                let first = inner.split(separator: ",").first,
                let value = Double(first)
            {
                offset = value
            }
            if let x = element.slice(from: " x=\"", to: "\""), let value = Double(x) {
                out.append(offset + value)
            }
        }
        return out
    }

    /// The y of each panel group, which is where a layout actually anchors itself.
    private func yOrigins(in svg: String) -> [Double] {
        svg.components(separatedBy: "<").compactMap { element in
            guard element.hasPrefix("g transform=\"translate("),
                let inner = element.slice(from: "translate(", to: ")"),
                let second = inner.split(separator: ",").last
            else { return nil }
            return Double(second)
        }
        // Tiles translate relative to the board's own group, so their small local offsets
        // are not absolute positions; only the outermost origin says where the strip sits.
        .filter { $0 > 1 }
    }

    private func attributes(_ name: String, in svg: String) -> [Double] {
        svg.components(separatedBy: "<").compactMap {
            guard let raw = $0.slice(from: " \(name)=\"", to: "\"") else { return nil }
            return Double(raw)
        }
    }

    private func widths(ofClass cls: String, in svg: String) -> [Double] {
        svg.components(separatedBy: "<").compactMap { element in
            guard let classes = element.slice(from: "class=\"", to: "\""),
                classes.split(separator: " ").contains(Substring(cls)),
                let raw = element.slice(from: " width=\"", to: "\"")
            else { return nil }
            return Double(raw)
        }
    }
}

extension String {
    fileprivate func slice(from: String, to: String) -> String? {
        guard let start = range(of: from),
            let end = self[start.upperBound...].range(of: to)
        else { return nil }
        return String(self[start.upperBound..<end.lowerBound])
    }
}
