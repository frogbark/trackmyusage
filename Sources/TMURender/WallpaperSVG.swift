import Foundation
import TMUProviders

/// The pixel dimensions the wallpaper is being drawn for.
public struct WallpaperCanvas: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let `default` = WallpaperCanvas(width: 2560, height: 1440)
}

/// How much of the picture to draw.
public enum WallpaperDensity: String, Sendable, CaseIterable, Equatable {
    /// A corner card: a few providers named, the rest compressed into a strip. Tasteful,
    /// icon-safe, and it tells you *that* something is off rather than what.
    case compact
    /// A left rail: every provider named and individually readable. The density that
    /// scales honestly to seventeen of them.
    case full
}

/// Renders a set of provider snapshots as an SVG overlay.
///
/// Pure text in, pure text out. Keeping the whole visual design a function of its inputs is
/// what lets a layout regression fail in `swift test` rather than appear on someone's
/// desktop, and it leaves rasterising as the only step that needs a platform.
///
/// Colours are written as presentation attributes rather than collected into a `<style>`
/// block. A stylesheet would name every state in every document, which both defeats tests
/// that check whether a state is actually present and leans on CSS support that rasterisers
/// implement unevenly.
public enum WallpaperSVG {

    /// How many providers the compact density names before compressing the remainder.
    public static let headlineCount = 4

    // The design space is 1440 units tall and scaled to whatever the display is, so one
    // set of sizes serves every resolution. Width follows the aspect ratio.
    private static let designHeight: Double = 1440

    private enum Ink {
        static let scrim = "#0c1216"
        static let primary = "#eaf0f2"
        static let muted = "#8b979e"
        static let track = "#ffffff"
        static let ok = "#4e8f78"
        static let warn = "#e0a24a"
        static let over = "#e2564a"
        static let absent = "#5b686f"
    }

    /// How a row should read at a glance.
    ///
    /// `uncapped` and `nodata` are deliberately separate. A provider reporting revenue has
    /// a perfectly good reading and simply no ceiling to measure it against; collapsing
    /// that into "no data" would hide a number we actually have.
    private enum State: String {
        case ok, warn, over, nodata, uncapped

        var ink: String {
            switch self {
            case .ok: return Ink.ok
            case .warn: return Ink.warn
            case .over: return Ink.over
            case .nodata: return Ink.absent
            case .uncapped: return Ink.muted
            }
        }
    }

    private struct Row {
        let name: String
        /// Nil when there is no cap to be a fraction of — which is also the signal not to
        /// draw a bar, since a bar with no track length is a lie about a limit.
        let utilization: Double?
        let display: String
        let state: State
    }

    // MARK: - Entry point

    public static func render(
        _ snapshots: [UsageSnapshot],
        density: WallpaperDensity,
        canvas: WallpaperCanvas,
        generatedAt: Date
    ) -> String {
        let scale = canvas.height > 0 ? canvas.height / designHeight : 1
        let designWidth = scale > 0 ? canvas.width / scale : canvas.width

        let rows = snapshots.map(row(for:))
        let body: String
        switch density {
        case .compact:
            body = compactCard(rows, designWidth: designWidth, at: generatedAt)
        case .full:
            body = fullRail(rows, at: generatedAt)
        }

        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(n(canvas.width))" \
            height="\(n(canvas.height))" viewBox="0 0 \(n(canvas.width)) \(n(canvas.height))">\
            <g transform="scale(\(n(scale)))">\(body)</g></svg>
            """
    }

    private static func row(for snapshot: UsageSnapshot) -> Row {
        guard snapshot.isReporting else {
            return Row(
                name: displayName(of: snapshot), utilization: nil, display: "no data",
                state: .nodata)
        }

        if let binding = snapshot.binding, let utilization = binding.utilization {
            let state: State =
                utilization >= 100 ? .over : (utilization >= 80 ? .warn : .ok)
            return Row(
                name: displayName(of: snapshot), utilization: utilization,
                display: "\(grouped(utilization.rounded()))%", state: state)
        }

        // Reporting, but nothing here has a ceiling. Show the reading in its own units.
        guard let first = snapshot.metrics.first else {
            return Row(
                name: displayName(of: snapshot), utilization: nil, display: "no data",
                state: .nodata)
        }
        return Row(
            name: displayName(of: snapshot), utilization: nil, display: measure(first),
            state: .uncapped)
    }

    /// What to call the row.
    ///
    /// The account wins where there is one. Several accounts of a single provider is the
    /// situation this project exists to manage, and labelling every one of them "claude"
    /// makes the wallpaper useless for exactly its main case. Where a credential identifies
    /// the account implicitly there is nothing to disambiguate, so the provider stands.
    private static func displayName(of snapshot: UsageSnapshot) -> String {
        snapshot.account ?? snapshot.provider
    }

    private static func measure(_ metric: Metric) -> String {
        switch metric.kind {
        case .currency: return "$\(grouped(metric.value))"
        case .percentOfLimit: return "\(grouped(metric.value))%"
        case .absolute, .count: return grouped(metric.value)
        }
    }

    // MARK: - Full: the left rail

    private static func fullRail(_ rows: [Row], at generatedAt: Date) -> String {
        let pad: Double = 26
        let rowHeight: Double = 44
        let width: Double = 400
        let headerHeight: Double = 44
        let height = headerHeight + Double(max(rows.count, 1)) * rowHeight + pad

        // Vertically centred rather than pinned to an edge, so it reads as part of the
        // picture instead of as a docked panel.
        let x: Double = 72
        let y = (designHeight - height) / 2

        // Stable order. Sorting by current usage would reshuffle the rail on every sample,
        // and a list whose rows move cannot be read at a glance — the same reason
        // MenuBarSummary fixes its order.
        let ordered = rows.sorted { $0.name < $1.name }

        var out = group(x: x, y: y)
        out += panel(width: width, height: height)
        out += label(
            "usage", x: pad, y: pad + 12, size: 17, ink: Ink.muted, letterSpacing: 0.08)
        out += label(
            time(generatedAt), x: width - pad, y: pad + 12, size: 17, ink: Ink.muted,
            anchor: "end")

        for (index, row) in ordered.enumerated() {
            let rowY = headerHeight + pad + Double(index) * rowHeight
            out += railRow(row, y: rowY, width: width, pad: pad)
        }
        return out + "</g>"
    }

    private static func railRow(_ row: Row, y: Double, width: Double, pad: Double)
        -> String
    {
        let trackWidth: Double = 104
        let trackX = width - pad - trackWidth
        let nameSize: Double = 20
        let hasBar = row.utilization != nil
        let valueSize: Double = hasBar ? 19 : 18
        let valueRight = hasBar ? trackX - 14 : width - pad

        // The value gets the space it needs and the name gets what is left. Reserving a
        // fixed name column instead would either waste the row on short names or still
        // collide on long ones, since the value's own width varies from "5%" to "$98,000".
        let nameLimit = valueRight - estimateWidth(row.display, size: valueSize) - pad - 12

        var out = "<g class=\"row \(row.state.rawValue)\">"
        out += label(
            truncate(row.name, size: nameSize, maxWidth: nameLimit),
            x: pad, y: y, size: nameSize, ink: Ink.primary)

        guard let utilization = row.utilization else {
            out += label(
                row.display, x: valueRight, y: y, size: valueSize,
                ink: row.state == .nodata ? Ink.absent : Ink.primary, anchor: "end")
            return out + "</g>"
        }

        // The number is reported unclamped, but the bar is clamped to its track — an
        // overflowing rect would paint straight over the label beside it.
        let filled = min(max(utilization, 0), 100) / 100 * trackWidth
        out += bar(
            class: "track", x: trackX, y: y - 7, width: trackWidth, ink: Ink.track,
            opacity: 0.13)
        if filled > 0 {
            out += bar(class: "fill", x: trackX, y: y - 7, width: filled, ink: row.state.ink)
        }
        out += label(
            row.display, x: valueRight, y: y, size: valueSize, ink: Ink.primary,
            anchor: "end")
        return out + "</g>"
    }

    // MARK: - Compact: the corner card

    private static func compactCard(_ rows: [Row], designWidth: Double, at generatedAt: Date)
        -> String
    {
        let pad: Double = 26
        let rowHeight: Double = 48
        let width: Double = 520
        let headerHeight: Double = 44

        // Headline by how full they are — the point of the compact density is the few that
        // matter — but drawn in name order so the card does not reshuffle as usage moves.
        let ranked = rows.sorted {
            ($0.utilization ?? -1, $1.name) > ($1.utilization ?? -1, $0.name)
        }
        let headline = Array(ranked.prefix(headlineCount)).sorted { $0.name < $1.name }
        let remainder = Array(ranked.dropFirst(headlineCount))

        let stripHeight: Double = remainder.isEmpty ? 0 : 46
        let height =
            headerHeight + Double(headline.count) * rowHeight + stripHeight + pad

        let x: Double = 72
        let y = designHeight - height - 96

        var out = group(x: x, y: y)
        out += panel(width: width, height: height)
        out += label(
            "usage", x: pad, y: pad + 12, size: 17, ink: Ink.muted, letterSpacing: 0.08)
        out += label(
            time(generatedAt), x: width - pad, y: pad + 12, size: 17, ink: Ink.muted,
            anchor: "end")

        for (index, row) in headline.enumerated() {
            let rowY = headerHeight + pad + Double(index) * rowHeight
            out += railRow(row, y: rowY, width: width, pad: pad)
        }

        if !remainder.isEmpty {
            let stripY = headerHeight + pad + Double(headline.count) * rowHeight
            out += strip(remainder, y: stripY, width: width, pad: pad)
        }
        return out + "</g>"
    }

    /// The remainder, as bare bars.
    ///
    /// Deliberately unlabelled: at this size a name would be unreadable, and the strip's
    /// job is only to say that something out here has moved, so you go and look.
    private static func strip(_ rows: [Row], y: Double, width: Double, pad: Double) -> String {
        let barWidth: Double = 8
        let gap: Double = 6
        let maxHeight: Double = 22
        var out = "<g class=\"strip\">"
        out += "<rect class=\"rule\" x=\"\(n(pad))\" y=\"\(n(y - 4))\" "
        out += "width=\"\(n(width - pad * 2))\" height=\"1\" fill=\"\(Ink.track)\" "
        out += "fill-opacity=\"0.14\"/>"

        for (index, row) in rows.enumerated() {
            let barX = pad + Double(index) * (barWidth + gap)
            if barX + barWidth > width - pad - 90 { break }
            let fraction = min(max(row.utilization ?? 0, 0), 100) / 100
            let barHeight = max(3, fraction * maxHeight)
            out += "<g class=\"row \(row.state.rawValue)\">"
            out +=
                "<rect class=\"fill\" x=\"\(n(barX))\" y=\"\(n(y + 18 + maxHeight - barHeight))\" "
            out += "width=\"\(n(barWidth))\" height=\"\(n(barHeight))\" rx=\"1\" "
            out += "fill=\"\(row.state.ink)\"/></g>"
        }
        out += label(
            "\(rows.count) more", x: width - pad, y: y + 34, size: 17, ink: Ink.muted,
            anchor: "end")
        return out + "</g>"
    }

    // MARK: - Primitives

    private static func group(x: Double, y: Double) -> String {
        "<g transform=\"translate(\(n(x)),\(n(y)))\">"
    }

    /// The scrim. Without it the overlay is illegible over a light photograph.
    private static func panel(width: Double, height: Double) -> String {
        "<rect class=\"panel\" x=\"0\" y=\"0\" width=\"\(n(width))\" height=\"\(n(height))\" "
            + "rx=\"18\" fill=\"\(Ink.scrim)\" fill-opacity=\"0.52\"/>"
    }

    private static func bar(
        class cls: String, x: Double, y: Double, width: Double, ink: String,
        opacity: Double = 1
    ) -> String {
        var out = "<rect class=\"\(cls)\" x=\"\(n(x))\" y=\"\(n(y))\" "
        out += "width=\"\(n(width))\" height=\"7\" rx=\"3\" fill=\"\(ink)\""
        if opacity < 1 { out += " fill-opacity=\"\(n(opacity))\"" }
        return out + "/>"
    }

    private static func label(
        _ text: String, x: Double, y: Double, size: Double, ink: String,
        anchor: String = "start", letterSpacing: Double = 0
    ) -> String {
        var out = "<text x=\"\(n(x))\" y=\"\(n(y))\" font-size=\"\(n(size))\" "
        out += "fill=\"\(ink)\" font-family=\"Inter, sans-serif\""
        if anchor != "start" { out += " text-anchor=\"\(anchor)\"" }
        if letterSpacing > 0 { out += " letter-spacing=\"\(n(letterSpacing))em\"" }
        return out + ">\(escape(text))</text>"
    }

    // MARK: - Formatting

    /// Provider names come from adapters and config, not from us. An unescaped ampersand
    /// yields a document that fails to parse, and that failure surfaces as a blank desktop
    /// rather than as an error anyone sees.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Numbers, without the trailing `.0` that `String(describing:)` leaves on integral
    /// doubles and without locale-dependent separators — a comma here is invalid SVG.
    private static func n(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    /// Roughly how wide a string will be.
    ///
    /// An approximation on purpose. Real advance widths would mean parsing the font, and
    /// the only decision resting on this is whether a name needs an ellipsis — a job that
    /// tolerates being a few percent out, and one that has to give the same answer on every
    /// platform. A ratio does; a font query does not.
    private static let glyphRatio: Double = 0.55

    private static func estimateWidth(_ text: String, size: Double) -> Double {
        Double(text.count) * size * glyphRatio
    }

    private static func truncate(_ text: String, size: Double, maxWidth: Double) -> String {
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

    /// Thousands separators, inserted by hand.
    ///
    /// A locale-aware formatter emits "98.000" or "98 000" depending on the machine, and
    /// the space it chooses is often non-breaking — which lands inside an SVG text node and
    /// rasterises differently per platform. The whole point of generating SVG once and
    /// rasterising it everywhere is that the output does not depend on the host.
    private static func grouped(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else { return n(value) }
        let whole = Int(abs(value).rounded())
        var out = ""
        for (index, character) in String(whole).reversed().enumerated() {
            if index > 0 && index % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }

    private static func time(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }
}
