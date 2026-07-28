import Foundation
import TMUDesign
import TMUTelemetry

extension SVG {

    /// Twelve small bars showing where a reading has been.
    ///
    /// Returns the empty string for fewer than two points, and that is the whole design.
    /// A single reading drawn as one bar — or worse, as a flat line across the width — is a
    /// claim about a trend that does not exist yet. This project already refuses to print a
    /// forecast it cannot measure and writes "no data" rather than zero; a sparkline
    /// invented from one sample would be the same lie in a different shape.
    ///
    /// Values are percentages. They are scaled against the tallest one present rather than
    /// against 100, because the point of the row's sparkline is the *shape* — the meter
    /// beside it already says the level.
    static func sparkline(
        _ values: [Double], x: Double, baseline: Double,
        barWidth: Double = 4, gap: Double = 2, maxHeight: Double = 18
    ) -> String {
        guard values.count >= 2 else { return "" }

        let recent = Array(values.suffix(12))
        let peak = recent.max() ?? 0
        guard peak > 0 else { return "" }

        var out = "<g class=\"spark\">"
        for (index, value) in recent.enumerated() {
            // A floor of 1pt so a genuine zero still reads as a sample that happened,
            // distinct from a gap where nothing was recorded.
            let height = max(1, min(max(value, 0), peak) / peak * maxHeight)
            out += bar(
                class: "spark-bar",
                x: x + Double(index) * (barWidth + gap),
                y: baseline - height,
                width: barWidth,
                height: height,
                radius: 1,
                ink: Ink.track.value,
                opacity: 0.28)
        }
        return out + "</g>"
    }

    /// How wide `sparkline` will be for a given count.
    static func sparklineWidth(
        count: Int, barWidth: Double = 4, gap: Double = 2
    ) -> Double {
        let bars = min(count, 12)
        guard bars >= 2 else { return 0 }
        return Double(bars) * barWidth + Double(bars - 1) * gap
    }
}
