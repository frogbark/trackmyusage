import ClaudrupleUsage
import Foundation
import XCTest

@testable import ClaudrupleRender

final class WallpaperSVGTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Helpers

    private func snapshot(
        _ provider: String, _ utilization: Double, key: String = "usage"
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: key, kind: .percentOfLimit, value: utilization,
                    limit: nil, window: .rolling(3600), resetsAt: nil)
            ])
    }

    private func unavailable(_ provider: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider, account: nil, observedAt: now,
            status: .unavailable("no public usage API"), metrics: [])
    }

    private func isWellFormed(_ svg: String) -> Bool {
        let parser = XMLParser(data: Data(svg.utf8))
        return parser.parse()
    }

    /// Widths of every `<rect>` carrying `cls`. The renderer writes `class` before
    /// `width`, which is what makes this a single expression rather than a parser.
    private func widths(ofClass cls: String, in svg: String) -> [Double] {
        let pattern = "<rect class=\"[^\"]*\(cls)[^\"]*\"[^>]*width=\"([0-9.]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(svg.startIndex..., in: svg)
        return re.matches(in: svg, range: range).compactMap { match in
            Range(match.range(at: 1), in: svg).flatMap { Double(svg[$0]) }
        }
    }

    // MARK: - The document

    func testOutputIsWellFormedXML() {
        let svg = WallpaperSVG.render(
            [snapshot("claude", 78), unavailable("openart")],
            density: .full, canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(isWellFormed(svg), "a malformed document rasterises to nothing at all")
    }

    func testTheCanvasSizeIsCarriedIntoTheDocument() {
        let svg = WallpaperSVG.render(
            [snapshot("claude", 40)], density: .compact,
            canvas: .init(width: 3840, height: 2160), generatedAt: now)

        XCTAssertTrue(svg.contains("width=\"3840\""))
        XCTAssertTrue(svg.contains("height=\"2160\""))
    }

    func testAnEmptyProviderListStillProducesAValidDocument() {
        // The first run, before any adapter has reported, must not emit a broken file that
        // then gets set as the desktop background.
        let svg = WallpaperSVG.render(
            [], density: .compact, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(isWellFormed(svg))
    }

    func testProviderNamesAreEscapedSoOneCannotBreakTheDocument() {
        // Provider identifiers are not ours — an adapter or a config file supplies them.
        // An unescaped ampersand produces a document that fails to parse, and the failure
        // shows up as a blank desktop rather than as an error.
        let svg = WallpaperSVG.render(
            [snapshot("A & B <script>", 30)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(isWellFormed(svg), "hostile provider names must not break parsing")
        XCTAssertTrue(svg.contains("A &amp; B &lt;script&gt;"))
        XCTAssertFalse(svg.contains("<script>"))
    }

    // MARK: - Density

    func testCompactNamesOnlyTheHeadlineProviders() {
        let many = (1...17).map { snapshot("provider\($0)", Double($0)) }
        let svg = WallpaperSVG.render(
            many, density: .compact, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        let named = (1...17).filter { svg.contains(">provider\($0)<") }
        XCTAssertEqual(
            named.count, WallpaperSVG.headlineCount,
            "the compact card names a few and compresses the rest into the strip")
    }

    func testFullNamesEveryProvider() {
        let many = (1...17).map { snapshot("provider\($0)", Double($0)) }
        let svg = WallpaperSVG.render(
            many, density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        let named = (1...17).filter { svg.contains(">provider\($0)<") }
        XCTAssertEqual(named.count, 17, "the rail is the density that scales to all of them")
    }

    // MARK: - States that must stay distinguishable

    func testUnavailableProvidersAreLabelledRatherThanDrawnAsZero() {
        // Drawing "we could not ask" as an empty bar reads as plenty of headroom, which is
        // the opposite of what is true.
        let svg = WallpaperSVG.render(
            [unavailable("openart")], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains("no data"), "absence is stated in words")
        XCTAssertTrue(svg.contains("nodata"), "and marked structurally for styling")
    }

    func testTheAccountNameLabelsTheRowWhenThereIsOne() {
        // Two accounts of one provider is the case this whole project exists for, and
        // labelling both rows "claude" makes the wallpaper useless for precisely that.
        // Caught by rendering real data: the machine has two Claude accounts and the rail
        // showed the same word twice.
        let accounts = ["Claude", "Claude Two"].map { name in
            UsageSnapshot(
                provider: "claude", account: name, observedAt: now, status: .ok,
                metrics: [
                    Metric(
                        key: "seven_day", kind: .percentOfLimit, value: 40, limit: nil,
                        window: .rolling(604_800), resetsAt: nil)
                ])
        }
        let svg = WallpaperSVG.render(
            accounts, density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(svg.contains(">Claude<"))
        XCTAssertTrue(svg.contains(">Claude Two<"))
    }

    func testTheProviderNameLabelsTheRowWhenThereIsNoAccount() {
        let svg = WallpaperSVG.render(
            [snapshot("vercel", 20)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains(">vercel<"), "one unnamed account needs no extra label")
    }

    func testALongProviderNameIsTruncatedRatherThanRunningIntoItsValue() {
        // Found by rendering rather than by asserting: "claude personal" overlapped its
        // own percentage. Nothing in the document is malformed when this happens, so only
        // looking at the pixels catches it — hence a test that pins the truncation.
        let long = "claude personal work experiments"
        let svg = WallpaperSVG.render(
            [snapshot(long, 34)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertFalse(svg.contains(long), "the full name cannot fit and must not be drawn")
        XCTAssertTrue(svg.contains("…"), "truncation is visible rather than silent")
        XCTAssertTrue(svg.contains("claude"), "the start of the name survives")
    }

    func testAShortNameIsLeftAlone() {
        let svg = WallpaperSVG.render(
            [snapshot("vercel", 34)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains(">vercel<"))
        XCTAssertFalse(svg.contains("…"), "nothing is truncated that fits")
    }

    func testAnUncappedProviderShowsItsValueRatherThanNoData() {
        // Stripe reports revenue, which has no cap at all. Labelling that "no data" is
        // wrong twice over: the reading is present, and having no limit is not the same
        // as having no measurement.
        let stripe = UsageSnapshot(
            provider: "stripe", account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "revenue_usd", kind: .currency, value: 98_000,
                    limit: nil, window: .calendarMonth, resetsAt: nil)
            ])
        let svg = WallpaperSVG.render(
            [stripe], density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertFalse(svg.contains("no data"), "the reading exists, it just has no cap")
        XCTAssertTrue(svg.contains("uncapped"), "but it is its own state, not a gauge")
        XCTAssertTrue(svg.contains("$98,000"), "shown in its own units")
    }

    func testALargeCountIsGroupedWithoutDependingOnLocale() {
        // A locale-aware formatter would emit "98.000" or "98 000" depending on the
        // machine, and a non-breaking space inside an SVG attribute is a rasteriser bug
        // waiting to happen. Grouping is done by hand for that reason.
        let seats = UsageSnapshot(
            provider: "github", account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "seats", kind: .count, value: 1_234_567,
                    limit: nil, window: .none, resetsAt: nil)
            ])
        let svg = WallpaperSVG.render(
            [seats], density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(svg.contains("1,234,567"))
    }

    func testAProviderOverItsLimitIsMarkedDistinctly() {
        let svg = WallpaperSVG.render(
            [snapshot("claude", 150)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains("over"), "past the cap is not the same as near it")
    }

    func testABarNeverOverflowsItsTrackWhenUtilisationExceedsOneHundred() {
        // The value is reported unclamped, but the drawn bar has to stay inside its track
        // or it paints over the labels beside it.
        let svg = WallpaperSVG.render(
            [snapshot("claude", 250)], density: .full,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(isWellFormed(svg))
        XCTAssertFalse(svg.contains("width=\"-"), "no negative geometry")

        let tracks = widths(ofClass: "track", in: svg)
        let fills = widths(ofClass: "fill", in: svg)
        XCTAssertFalse(tracks.isEmpty, "the test is meaningless if it matched nothing")
        XCTAssertFalse(fills.isEmpty)
        for fill in fills {
            XCTAssertLessThanOrEqual(
                fill, tracks.max() ?? 0,
                "the fill is clamped to the track even though the number is not")
        }
    }

    // MARK: - Determinism

    func testRenderingTheSameInputTwiceProducesIdenticalOutput() {
        // The daemon re-renders on a timer and compares against the last write. Any
        // instability here means the wallpaper is rewritten every cycle for no reason.
        let input = [snapshot("claude", 78), unavailable("openart"), snapshot("vercel", 12)]
        let a = WallpaperSVG.render(
            input, density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)
        let b = WallpaperSVG.render(
            input, density: .full, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertEqual(a, b)
    }
}
