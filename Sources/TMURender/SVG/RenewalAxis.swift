import Foundation
import TMUDesign
import TMUTelemetry

extension SVG {

    /// A thirty-day timeline with a tick per upcoming renewal.
    ///
    /// The point is the shape of the month rather than the dates: four renewals bunched into
    /// one week reads very differently from four spread evenly, and that is not something a
    /// list of dates conveys at a glance from across a room.
    ///
    /// Ticks are held inside 90% of the width. A renewal 29 days out otherwise lands its
    /// label half off the panel, and a clipped date is worse than a slightly compressed axis.
    static func renewalAxis(
        _ renewals: [TelemetryModel.Renewal], x: Double, y: Double, width: Double,
        horizonDays: Double = 30
    ) -> String {
        guard !renewals.isEmpty else { return "" }

        let usable = width * 0.9
        var out = group(x: x, y: y)
        out += "<rect class=\"axis\" x=\"0\" y=\"0\" width=\"\(Format.svg(width))\" "
        out += "height=\"2\" rx=\"1\" fill=\"\(Ink.track.value)\" fill-opacity=\"0.14\"/>"

        // Two renewals on the same day would stack their labels on top of each other; keep
        // the first and let the rest fall into the "renews —" line instead.
        var used: [Double] = []
        for renewal in renewals {
            let fraction = min(max(Double(renewal.daysAway) / horizonDays, 0), 1)
            let tickX = fraction * usable
            guard !used.contains(where: { abs($0 - tickX) < 44 }) else { continue }
            used.append(tickX)

            out += label(
                truncate(renewal.name, size: 13, maxWidth: 84),
                x: tickX, y: -8, size: 13, ink: Ink.muted.value, anchor: "middle")
            out += "<rect class=\"tick \(renewal.state.rawValue)\" "
            out += "x=\"\(Format.svg(tickX - 1.5))\" y=\"-5\" width=\"3\" height=\"12\" "
            out += "fill=\"\(renewal.state.ink.value)\"/>"
            out += label(
                Format.daysAway(renewal.daysAway),
                x: tickX, y: 22, size: 12, ink: Ink.muted.value, anchor: "middle")
        }
        return out + "</g>"
    }

    /// `renews — vercel 3d · twilio 11d · supabase 28d`
    ///
    /// The rail's version of the same information, where there is no room for an axis.
    static func renewalLine(
        _ renewals: [TelemetryModel.Renewal], x: Double, y: Double, width: Double,
        limit: Int = 3
    ) -> String {
        guard !renewals.isEmpty else { return "" }
        let parts = renewals.prefix(limit).map {
            "\($0.name) \(Format.daysAway($0.daysAway))"
        }
        let text = "renews — " + parts.joined(separator: " · ")
        return label(
            truncate(text, size: 17, maxWidth: width),
            x: x, y: y, size: 17, ink: Ink.muted.value)
    }
}
