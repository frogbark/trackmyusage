import Foundation
import TMUDesign
import TMUTelemetry

/// The pieces every layout is built from.
///
/// Pure functions returning strings, deliberately — not a stateful builder. They are already
/// deterministic and covered; converting them to a builder would be churn that buys no test
/// surface. Kept `internal` so the layouts share them and nothing outside this target can
/// assemble half an SVG.
enum SVG {

    /// The typeface, named for CoreText.
    ///
    /// macOS rasterises this SVG through `NSImage`, which resolves families via CoreText —
    /// where `-apple-system` and `system-ui` mean nothing, and neither did the `Inter` this
    /// used to ask for, since it is not installed on a stock Mac. The design calls for
    /// tabular numerals; `font-variant-numeric` is a CSS property with no presentation-
    /// attribute form and `<style>` blocks are ruled out, so the figures come from the font
    /// choice itself. SF Pro Text has tabular figures in its default set.
    static let fontFamily = "SF Pro Text, Helvetica Neue, sans-serif"

    /// Wrap one reading's marks in a group carrying its state.
    ///
    /// This is how a layout says "this row is over its limit" structurally rather than only
    /// through a colour. The tests assert on these classes — checking that `over` is present
    /// at all, not merely that something is reddish — and a rasteriser that ignores classes
    /// (all of them do) is unaffected. Dropping it makes the tests pass while checking
    /// nothing, which is exactly what happened once already.
    static func row(_ state: UsageState, _ contents: String) -> String {
        "<g class=\"row \(state.rawValue)\">\(contents)</g>"
    }

    static func group(x: Double, y: Double) -> String {
        "<g transform=\"translate(\(Format.svg(x)),\(Format.svg(y)))\">"
    }

    /// The scrim. Without it the overlay is illegible over a light photograph.
    ///
    /// Opacity is a parameter because the attention state changes it: 35% when everything is
    /// calm, 72–78% when something needs reading.
    static func panel(
        width: Double, height: Double, radius: Double = 18, opacity: Double = 0.52
    ) -> String {
        "<rect class=\"panel\" x=\"0\" y=\"0\" width=\"\(Format.svg(width))\" "
            + "height=\"\(Format.svg(height))\" rx=\"\(Format.svg(radius))\" "
            + "fill=\"\(Ink.scrim.value)\" fill-opacity=\"\(Format.svg(opacity))\"/>"
    }

    /// A rounded rectangle.
    ///
    /// `radius` is explicit rather than derived from the height. Deriving it as `height / 2`
    /// is right for a meter and wrong for anything short: a 4pt sparkline bar becomes a
    /// circle, and a strip of them reads as a row of dots rather than a bar chart.
    static func bar(
        class cls: String, x: Double, y: Double, width: Double, height: Double = 7,
        radius: Double? = nil, ink: String, opacity: Double = 1
    ) -> String {
        var out = "<rect class=\"\(cls)\" x=\"\(Format.svg(x))\" y=\"\(Format.svg(y))\" "
        out += "width=\"\(Format.svg(max(0, width)))\" height=\"\(Format.svg(height))\" "
        out += "rx=\"\(Format.svg(radius ?? min(height / 2, 5)))\" fill=\"\(ink)\""
        if opacity < 1 { out += " fill-opacity=\"\(Format.svg(opacity))\"" }
        return out + "/>"
    }

    /// A bar and its track, clamped.
    ///
    /// The *number* is never clamped — 104% is reported as 104% — but the rectangle is, or
    /// an overflowing fill paints straight over the label beside it.
    /// A bar and its track, clamped — or nothing at all.
    ///
    /// A row with no utilisation draws *no meter*, not an empty track. Revenue has no
    /// ceiling and a failed provider has no reading; an empty track beside either one is a
    /// gauge reading zero, which is exactly the "absence drawn as zero" this project refuses
    /// everywhere else.
    static func meter(
        x: Double, y: Double, trackWidth: Double, height: Double, utilization: Double?,
        ink: String
    ) -> String {
        guard let utilization else { return "" }
        var out = bar(
            class: "track", x: x, y: y, width: trackWidth, height: height,
            ink: Ink.track.value, opacity: 0.13)
        let filled = min(max(utilization, 0), 100) / 100 * trackWidth
        if filled > 0 {
            out += bar(class: "fill", x: x, y: y, width: filled, height: height, ink: ink)
        }
        return out
    }

    static func label(
        _ text: String, x: Double, y: Double, size: Double, ink: String,
        anchor: String = "start", weight: Int? = nil, letterSpacing: Double = 0,
        opacity: Double = 1
    ) -> String {
        var out = "<text x=\"\(Format.svg(x))\" y=\"\(Format.svg(y))\" "
        out += "font-size=\"\(Format.svg(size))\" fill=\"\(ink)\" font-family=\"\(fontFamily)\""
        if let weight { out += " font-weight=\"\(weight)\"" }
        if anchor != "start" { out += " text-anchor=\"\(anchor)\"" }
        if letterSpacing > 0 {
            out += " letter-spacing=\"\(Format.svg(letterSpacing))em\""
        }
        if opacity < 1 { out += " fill-opacity=\"\(Format.svg(opacity))\"" }
        return out + ">\(escape(text))</text>"
    }

    /// A hairline divider.
    static func rule(x: Double, y: Double, width: Double, opacity: Double = 0.12) -> String {
        "<rect class=\"rule\" x=\"\(Format.svg(x))\" y=\"\(Format.svg(y))\" "
            + "width=\"\(Format.svg(width))\" height=\"1\" fill=\"\(Ink.track.value)\" "
            + "fill-opacity=\"\(Format.svg(opacity))\"/>"
    }

    /// The lowercase wordmark the wallpapers carry.
    static func wordmark(x: Double, y: Double, size: Double = 19) -> String {
        label(
            "trackmyusage", x: x, y: y, size: size, ink: Ink.muted.value,
            letterSpacing: 0.12)
    }

    // MARK: - Text fitting

    /// Roughly how wide a string will be.
    ///
    /// An approximation on purpose. Real advance widths would mean parsing the font, and the
    /// only decision resting on this is whether a name needs an ellipsis — a job that
    /// tolerates being a few percent out, and one that has to give the same answer on every
    /// platform. A ratio does; a font query does not.
    static let glyphRatio: Double = 0.55

    static func estimateWidth(_ text: String, size: Double) -> Double {
        Double(text.count) * size * glyphRatio
    }

    static func truncate(_ text: String, size: Double, maxWidth: Double) -> String {
        guard maxWidth > 0 else { return "…" }
        guard estimateWidth(text, size: size) > maxWidth else { return text }
        var characters = Array(text)
        while !characters.isEmpty,
            estimateWidth(String(characters) + "…", size: size) > maxWidth
        {
            characters.removeLast()
        }
        return characters.isEmpty ? "…" : String(characters) + "…"
    }

    /// Provider names come from adapters and config, not from us. An unescaped ampersand
    /// yields a document that fails to parse, and that failure surfaces as a blank desktop
    /// rather than as an error anyone sees.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
