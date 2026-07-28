import Foundation

/// Three ascending bars on a dark tile.
///
/// Defined once, here, as geometry rather than as a file. One definition then serves the app
/// icon, the menu bar glyph, the website nav mark, the favicon and the social preview — and
/// none of them can drift from the others, which is what happens the moment a mark becomes
/// five exported PNGs in five places.
///
/// It is also the reason the mark is testable at all: bar heights and gaps are numbers a test
/// can assert on, where an image is something a person has to remember to look at.
public enum BrandMark {

    /// The tile the proportions are defined against. Everything scales from this.
    public static let designTile: Double = 84

    /// Ascending, in design units. The eye reads three rising bars as a meter before it reads
    /// them as a logo, which is the whole idea.
    public static let barHeights: [Double] = [17, 31, 47]
    public static let barWidth: Double = 11
    public static let barGap: Double = 6
    public static let barRadius: Double = 3

    /// Proportional, so the tile keeps its shape at 16pt and at 1024.
    public static let tileRadiusRatio: Double = 0.24

    /// The third bar is amber: the mark says "one of these is running hot" even at 16 points,
    /// where nothing else on screen could.
    public static func ink(forBar index: Int) -> Hex {
        index == barHeights.count - 1 ? Ink.warn : Ink.ok
    }

    public static var contentWidth: Double {
        Double(barHeights.count) * barWidth + Double(barHeights.count - 1) * barGap
    }

    /// The mark as a standalone SVG document.
    ///
    /// `tile: false` drops the background — the website nav wants bars on its own surface,
    /// the app icon wants the tile. macOS does not mask app icons, so the generator has to
    /// draw the rounded rectangle itself.
    public static func svg(size: Double, tile: Bool = true) -> String {
        let scale = size / designTile
        let inset = (size - contentWidth * scale) / 2
        // Optically centred: the bars are bottom-aligned, so splitting the leftover height
        // evenly would make the mark sit high in its tile.
        let baseline = size - inset

        var out = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(number(size))" \
            height="\(number(size))" viewBox="0 0 \(number(size)) \(number(size))">
            """

        if tile {
            out += """
                <defs><linearGradient id="tmu-tile" x1="0" y1="0" x2="0.34" y2="1">\
                <stop offset="0" stop-color="#131c22"/>\
                <stop offset="1" stop-color="#0a1013"/></linearGradient></defs>\
                <rect x="0" y="0" width="\(number(size))" height="\(number(size))" \
                rx="\(number(size * tileRadiusRatio))" fill="url(#tmu-tile)"/>
                """
        }

        for (index, height) in barHeights.enumerated() {
            let barHeight = height * scale
            out += """
                <rect x="\(number(inset + Double(index) * (barWidth + barGap) * scale))" \
                y="\(number(baseline - barHeight))" \
                width="\(number(barWidth * scale))" height="\(number(barHeight))" \
                rx="\(number(barRadius * scale))" fill="\(ink(forBar: index).value)"/>
                """
        }
        return out + "</svg>"
    }

    /// Locale-free, and without the trailing `.0` that would be invalid in some attributes.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9
            ? String(Int(value)) : String(format: "%.3f", value)
    }
}
