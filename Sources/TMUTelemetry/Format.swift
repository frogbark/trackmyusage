import Foundation
import TMUProviders

/// Turning numbers into the strings people read.
///
/// Locale-free on purpose. These strings are compared byte for byte in `web/widgets.json`,
/// and a machine set to a comma-decimal locale would otherwise produce a different file and
/// fail CI for reasons that have nothing to do with the change under review.
/// `NumberFormatter` is the usual answer and is exactly the wrong one here.
public enum Format {

    /// A number for an SVG attribute: integral where possible, two decimals otherwise.
    public static func svg(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    /// A number for a person: thousands separated, rounded to whole units.
    public static func grouped(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else { return svg(value) }
        let whole = Int(abs(value).rounded())
        var out = ""
        for (index, character) in String(whole).reversed().enumerated() {
            if index > 0 && index % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }

    /// A metric with no ceiling, shown in its own units.
    public static func measure(_ metric: Metric) -> String {
        switch metric.kind {
        case .currency: return "$\(grouped(metric.value))"
        case .percentOfLimit: return "\(grouped(metric.value))%"
        case .absolute, .count: return grouped(metric.value)
        }
    }

    /// `HH:mm`, in the zone it is given.
    ///
    /// The zone is a parameter rather than `TimeZone.current` read here. Reading it made
    /// rendering a function of its inputs *and* the machine: the same instant drew 20:33 on a
    /// laptop and 03:33 on a UTC runner, which is how the committed images came to disagree
    /// with the ones CI regenerated. `generate-web.sh` pinned `TZ=UTC` to paper over it, and
    /// an environment variable in a shell script is a strange place to keep a property the
    /// project states as an invariant.
    public static func time(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "3d", "11d", "today" — how a renewal reads on the large widget's renewal line.
    public static func daysAway(_ days: Int) -> String {
        days <= 0 ? "today" : "\(days)d"
    }
}
