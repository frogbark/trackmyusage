import Foundation
import TMUDesign
import TMUTelemetry

/// 4c and 4d — the corner card, in its quiet and alert forms.
///
/// Attention is a *modifier* here rather than a fourth layout. The two states differ in
/// scrim opacity, overall opacity, which rows are drawn and whether there is a footer;
/// splitting them into separate layout types would duplicate the renewal axis and the strip
/// for the sake of an `if`.
enum CompactCard {

    static let x: Double = 96
    static let bottomMargin: Double = 130
    static let pad: Double = 32
    static let radius: Double = 24

    /// How many services are named before the rest become anonymous bars.
    static let headlineCount = 4

    static func render(_ model: TelemetryModel, designHeight: Double) -> String {
        switch model.attention {
        case .quiet: return quiet(model, designHeight: designHeight)
        case .alert: return alert(model, designHeight: designHeight)
        }
    }

    // MARK: - Quiet

    /// Everything is under 80%. The panel dims to a whisper and stops enumerating.
    ///
    /// Silence is information. A panel that looks identical whether things are fine or on
    /// fire has taught you to ignore it, so the calm state deliberately gives up detail —
    /// the accounts, and one line confirming the rest was checked.
    private static func quiet(_ model: TelemetryModel, designHeight: Double) -> String {
        let width: Double = 380
        let rowHeight: Double = 40
        let height =
            56 + Double(model.claude.count) * rowHeight + (model.services.isEmpty ? 0 : 30)
            + pad

        var out = SVG.group(x: x, y: designHeight - height - bottomMargin)
        // Two opacities compounding, deliberately: the scrim thins so the photograph shows
        // through, and the whole group fades so the text recedes with it.
        out += "<g opacity=\"0.62\">"
        out += SVG.panel(width: width, height: height, radius: radius, opacity: 0.35)
        out += SVG.wordmark(x: pad, y: pad, size: 15)
        out += SVG.label(
            Format.time(model.generatedAt), x: width - pad, y: pad, size: 15,
            ink: Ink.muted.value, anchor: "end")

        var cursor = 56.0 + pad / 2
        for account in model.claude {
            let ink = Freshness.ink(for: account.state, stale: account.isStale).value
            out += "<g class=\"row \(account.state.rawValue)\">"
            out += SVG.label(
                SVG.truncate(account.name, size: 15, maxWidth: width - pad * 2 - 70),
                x: pad, y: cursor, size: 15, ink: Ink.primary.value)
            out += SVG.label(
                account.display, x: width - pad, y: cursor, size: 15, ink: ink,
                anchor: "end")
            out += SVG.meter(
                x: pad, y: cursor + 14, trackWidth: width - pad * 2, height: 5,
                utilization: account.utilization, ink: ink)
            out += "</g>"
            cursor += rowHeight
        }

        if !model.services.isEmpty {
            out += SVG.label(
                "\(model.services.count) services · all under \(Int(Thresholds.warn))%",
                x: pad, y: cursor + 4, size: 13, ink: Ink.muted.value)
        }
        return out + "</g></g>"
    }

    // MARK: - Alert

    /// Something is at or past 80%. The panel grows, brightens, and leads with the offender.
    private static func alert(_ model: TelemetryModel, designHeight: Double) -> String {
        let width: Double = 620
        let rowHeight: Double = 46

        // Rank by how full, take the headline, then draw those in name order. Ranking picks
        // *which* rows matter; drawing alphabetically keeps the card from reshuffling as
        // usage moves, which is what makes it readable at a glance.
        let ranked = model.services.sorted {
            let left = $0.utilization ?? -1
            let right = $1.utilization ?? -1
            return left == right ? $0.name < $1.name : left > right
        }
        let headline = Array(ranked.prefix(headlineCount)).sorted { $0.name < $1.name }
        let remainder = Array(ranked.dropFirst(headlineCount))

        let accountHeight: Double = 58
        let stripHeight: Double = remainder.isEmpty ? 0 : 46
        let axisHeight: Double = model.renewals.isEmpty ? 0 : 66
        let height =
            56 + Double(model.claude.count) * accountHeight
            + Double(headline.count) * rowHeight + stripHeight + axisHeight + pad

        var out = SVG.group(x: x, y: designHeight - height - bottomMargin)
        out += SVG.panel(width: width, height: height, radius: radius, opacity: 0.78)
        out += SVG.wordmark(x: pad, y: pad)
        out += SVG.label(
            Format.time(model.generatedAt), x: width - pad, y: pad, size: 19,
            ink: Ink.muted.value, anchor: "end")

        var cursor = 56.0 + pad / 2
        for account in model.claude {
            let ink = Freshness.ink(for: account.state, stale: account.isStale).value
            out += "<g class=\"row \(account.state.rawValue)\">"
            out += SVG.label(
                SVG.truncate(account.name, size: 21, maxWidth: width - pad * 2 - 110),
                x: pad, y: cursor, size: 21, ink: Ink.primary.value, weight: 600)
            out += SVG.label(
                account.display, x: width - pad, y: cursor + 4, size: 28, ink: ink,
                anchor: "end", weight: 700)
            out += SVG.meter(
                x: pad, y: cursor + 16, trackWidth: width - pad * 2, height: 8,
                utilization: account.utilization, ink: ink)
            out += "</g>"
            cursor += accountHeight
        }

        for service in headline {
            let ink = Freshness.ink(for: service.state, stale: service.isStale).value
            out += "<g class=\"row \(service.state.rawValue)\">"
            out += SVG.label(
                SVG.truncate(service.name, size: 19, maxWidth: 150),
                x: pad, y: cursor, size: 19,
                ink: service.state == .nodata ? Ink.absent.value : Ink.primary.value)
            out += SVG.meter(
                x: pad + 160, y: cursor - 8, trackWidth: width - pad * 2 - 160 - 100,
                height: 7, utilization: service.utilization, ink: ink)
            out += SVG.label(
                service.display, x: width - pad, y: cursor, size: 19,
                ink: service.state == .nodata ? Ink.absent.value : Ink.primary.value,
                anchor: "end")
            out += "</g>"
            cursor += rowHeight
        }

        if !remainder.isEmpty {
            out += strip(remainder, y: cursor, width: width)
            cursor += stripHeight
        }
        if !model.renewals.isEmpty {
            out += SVG.renewalAxis(
                model.renewals, x: pad, y: cursor + 26, width: width - pad * 2)
        }
        return out + "</g>"
    }

    /// The remainder, as bare unlabelled bars.
    ///
    /// Deliberately without names: at this size a label would be unreadable, and the strip's
    /// only job is to say that something out here has moved so you go and look.
    private static func strip(
        _ rows: [TelemetryModel.ServiceRow], y: Double, width: Double
    ) -> String {
        let barWidth: Double = 8
        let gap: Double = 6
        let maxHeight: Double = 22

        // Rows with no utilisation cannot be a bar height. Drawing them at the 3pt floor
        // puts "revenue, no ceiling" and "provider is down" on the strip as though they were
        // readings near zero. They stay in the count instead.
        let measurable = rows.filter { $0.utilization != nil }

        var out = SVG.rule(x: pad, y: y, width: width - pad * 2, opacity: 0.14)
        var barX = pad
        var drawn = 0
        for row in measurable {
            guard barX + barWidth <= width - pad - 90 else { break }
            let fraction = min(max(row.utilization ?? 0, 0), 100) / 100
            let height = max(3, fraction * maxHeight)
            let ink = Freshness.ink(for: row.state, stale: row.isStale).value
            out += SVG.bar(
                class: "fill \(row.state.rawValue)", x: barX, y: y + 12 + maxHeight - height,
                width: barWidth, height: height, radius: 1, ink: ink)
            barX += barWidth + gap
            drawn += 1
        }
        if drawn < rows.count {
            out += SVG.label(
                "\(rows.count - drawn) more", x: width - pad, y: y + 32, size: 17,
                ink: Ink.muted.value, anchor: "end")
        }
        return out
    }
}
