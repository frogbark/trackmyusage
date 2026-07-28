import Foundation
import TMUProviders
import XCTest

@testable import TMURender

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
            layout: .ledger, canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(isWellFormed(svg), "a malformed document rasterises to nothing at all")
    }

    func testTheCanvasSizeIsCarriedIntoTheDocument() {
        let svg = WallpaperSVG.render(
            [snapshot("claude", 40)], layout: .card,
            canvas: .init(width: 3840, height: 2160), generatedAt: now)

        XCTAssertTrue(svg.contains("width=\"3840\""))
        XCTAssertTrue(svg.contains("height=\"2160\""))
    }

    func testAnEmptyProviderListStillProducesAValidDocument() {
        // The first run, before any adapter has reported, must not emit a broken file that
        // then gets set as the desktop background.
        let svg = WallpaperSVG.render(
            [], layout: .card, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(isWellFormed(svg))
    }

    func testProviderNamesAreEscapedSoOneCannotBreakTheDocument() {
        // Provider identifiers are not ours — an adapter or a config file supplies them.
        // An unescaped ampersand produces a document that fails to parse, and the failure
        // shows up as a blank desktop rather than as an error.
        // Short enough to survive the rail's 128pt name column; the escaping is the point,
        // not the truncation.
        let svg = WallpaperSVG.render(
            [snapshot("a&b<i>", 30)], layout: .ledger,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(isWellFormed(svg), "hostile provider names must not break parsing")
        XCTAssertTrue(svg.contains("a&amp;b&lt;i&gt;"))
        XCTAssertFalse(svg.contains("<i>"))
    }

    // MARK: - Density

    func testTheCardNamesOnlyTheHeadlineProvidersWhenAlerting() {
        // One provider past 80% puts the card into its alert state, which is the only state
        // that enumerates services at all.
        let many = (1...17).map { snapshot("provider\($0)", Double($0) * 6) }
        let svg = WallpaperSVG.render(
            many, layout: .card, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        let named = (1...17).filter { svg.contains(">provider\($0)<") }
        XCTAssertEqual(
            named.count, WallpaperSVG.headlineCount,
            "the card names a few and compresses the rest into the strip")
    }

    /// Silence is information. A panel that looks the same whether things are fine or on
    /// fire has taught you to ignore it, so the calm state gives up detail on purpose.
    func testTheCardGoesQuietWhenNothingIsNearItsLimit() {
        let calm = (1...17).map { snapshot("provider\($0)", Double($0)) }
        let svg = WallpaperSVG.render(
            calm, layout: .card, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        let named = (1...17).filter { svg.contains(">provider\($0)<") }
        XCTAssertTrue(named.isEmpty, "the quiet card does not enumerate services")
        XCTAssertTrue(
            svg.contains("17 services · all under 80%"),
            "but it must say what it checked, or silence is indistinguishable from broken")
        XCTAssertTrue(svg.contains("opacity=\"0.62\""), "and it must actually recede")
    }

    func testFullNamesEveryProvider() {
        let many = (1...17).map { snapshot("provider\($0)", Double($0)) }
        let svg = WallpaperSVG.render(
            many, layout: .ledger, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        let named = (1...17).filter { svg.contains(">provider\($0)<") }
        XCTAssertEqual(named.count, 17, "the rail is the density that scales to all of them")
    }

    // MARK: - States that must stay distinguishable

    func testUnavailableProvidersAreLabelledRatherThanDrawnAsZero() {
        // Drawing "we could not ask" as an empty bar reads as plenty of headroom, which is
        // the opposite of what is true.
        let svg = WallpaperSVG.render(
            [unavailable("openart")], layout: .ledger,
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
            accounts, layout: .ledger, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(svg.contains(">Claude<"))
        XCTAssertTrue(svg.contains(">Claude Two<"))
    }

    func testTheProviderNameLabelsTheRowWhenThereIsNoAccount() {
        let svg = WallpaperSVG.render(
            [snapshot("vercel", 20)], layout: .ledger,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains(">vercel<"), "one unnamed account needs no extra label")
    }

    func testALongProviderNameIsTruncatedRatherThanRunningIntoItsValue() {
        // Found by rendering rather than by asserting: "claude personal" overlapped its
        // own percentage. Nothing in the document is malformed when this happens, so only
        // looking at the pixels catches it — hence a test that pins the truncation.
        let long = "claude personal work experiments"
        let svg = WallpaperSVG.render(
            [snapshot(long, 34)], layout: .ledger,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertFalse(svg.contains(long), "the full name cannot fit and must not be drawn")
        XCTAssertTrue(svg.contains("…"), "truncation is visible rather than silent")
        XCTAssertTrue(svg.contains("claude"), "the start of the name survives")
    }

    func testAShortNameIsLeftAlone() {
        let svg = WallpaperSVG.render(
            [snapshot("vercel", 34)], layout: .ledger,
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
            [stripe], layout: .ledger, canvas: .init(width: 2560, height: 1440),
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
            [seats], layout: .ledger, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertTrue(svg.contains("1,234,567"))
    }

    func testAProviderOverItsLimitIsMarkedDistinctly() {
        let svg = WallpaperSVG.render(
            [snapshot("claude", 150)], layout: .ledger,
            canvas: .init(width: 2560, height: 1440), generatedAt: now)

        XCTAssertTrue(svg.contains("over"), "past the cap is not the same as near it")
    }

    func testABarNeverOverflowsItsTrackWhenUtilisationExceedsOneHundred() {
        // The value is reported unclamped, but the drawn bar has to stay inside its track
        // or it paints over the labels beside it.
        let svg = WallpaperSVG.render(
            [snapshot("claude", 250)], layout: .ledger,
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
            input, layout: .ledger, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)
        let b = WallpaperSVG.render(
            input, layout: .ledger, canvas: .init(width: 2560, height: 1440),
            generatedAt: now)

        XCTAssertEqual(a, b)
    }

    /// The compact card ranks by utilisation and then by name. The tiebreak used to compare
    /// `$1.name` against `$0.name` — swapped across the tuples — so equal percentages came
    /// out in reverse. Invisible whenever two providers differ, which is nearly always.
    func testProvidersAtTheSamePercentageAreOrderedByName() {
        let tied = ["delta", "alpha", "charlie", "bravo", "echo"].map {
            snapshot($0, 85)
        }
        let svg = WallpaperSVG.render(
            tied, layout: .card, canvas: .default, generatedAt: now)

        // Four are headlined and drawn in name order; "echo" falls into the strip.
        let order = ["alpha", "bravo", "charlie", "delta"].map {
            svg.range(of: ">\($0)<")?.lowerBound
        }
        XCTAssertFalse(order.contains(where: { $0 == nil }), "all four should be headlined")
        XCTAssertEqual(
            order.compactMap { $0 }, order.compactMap { $0 }.sorted(),
            "Rows at equal utilisation must read alphabetically, not backwards.")
    }

}
