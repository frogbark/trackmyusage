import Foundation
import TMUDesign
import TMUTelemetry

/// 1d — the ledger rail. Every provider named and individually readable.
///
/// The density that scales honestly to seventeen services: nothing is compressed into an
/// anonymous bar, so the panel answers "what is at 94%" rather than only "something is".
/// It needs a large display; `MissionBoard` and `CompactCard` are the answers for the rest.
enum LedgerRail {

    static let x: Double = 96
    static let top: Double = 240
    static let width: Double = 520
    static let pad: Double = 36
    static let radius: Double = 26

    static func render(_ model: TelemetryModel, designHeight: Double) -> String {
        let headerHeight: Double = 56
        let accountHeight: Double = 108
        let serviceHeight: Double = 40
        let dividerGap: Double = 24

        let accountsHeight = Double(model.claude.count) * accountHeight
        let servicesHeight = Double(model.services.count) * serviceHeight
        let renewalHeight: Double = model.renewals.isEmpty ? 0 : 44
        let height =
            headerHeight + accountsHeight
            + (model.services.isEmpty ? 0 : dividerGap + servicesHeight)
            + renewalHeight + pad

        var out = SVG.group(x: x, y: top)
        out += SVG.panel(width: width, height: height, radius: radius, opacity: 0.72)
        out += SVG.wordmark(x: pad, y: pad + 14)
        out += SVG.label(
            Format.time(model.generatedAt), x: width - pad, y: pad + 14, size: 19,
            ink: Ink.muted.value, anchor: "end")

        var cursor = headerHeight + pad
        for account in model.claude {
            out += accountBlock(account, y: cursor)
            cursor += accountHeight
        }

        if !model.services.isEmpty {
            out += SVG.rule(x: pad, y: cursor - 4, width: width - pad * 2)
            cursor += dividerGap - 4
            for service in model.services {
                out += serviceRow(service, y: cursor)
                cursor += serviceHeight
            }
        }

        if !model.renewals.isEmpty {
            out += SVG.rule(x: pad, y: cursor + 2, width: width - pad * 2)
            out += SVG.renewalLine(
                model.renewals, x: pad, y: cursor + 30, width: width - pad * 2)
        }
        return out + "</g>"
    }

    /// Name, a large percentage, a thick meter, and what the number is *of*.
    ///
    /// Accounts get an order of magnitude more space than services because they are the
    /// thing being managed; a service at 40% is context, an account at 96% is a decision.
    private static func accountBlock(_ row: TelemetryModel.AccountRow, y: Double) -> String {
        SVG.row(row.state, accountMarks(row, y: y))
    }

    private static func accountMarks(_ row: TelemetryModel.AccountRow, y: Double) -> String {
        let ink = Freshness.ink(for: row.state, stale: row.isStale).value
        var out = SVG.label(
            SVG.truncate(row.name, size: 28, maxWidth: width - pad * 2 - 130),
            x: pad, y: y + 8, size: 28, ink: Ink.primary.value, weight: 600)
        out += SVG.label(
            row.display, x: width - pad, y: y + 14, size: 42, ink: ink, anchor: "end",
            weight: 700)
        out += SVG.meter(
            x: pad, y: y + 32, trackWidth: width - pad * 2, height: 10,
            utilization: row.utilization, ink: ink)
        if let window = row.windowLabel {
            out += SVG.label(
                window, x: pad, y: y + 68, size: 18, ink: Ink.muted.value)
        }
        return out
    }

    /// Name, sparkline, meter, value — four columns that stay in their lanes so the eye can
    /// scan any one of them down the list without following the others.
    private static func serviceRow(_ row: TelemetryModel.ServiceRow, y: Double) -> String {
        SVG.row(row.state, serviceMarks(row, y: y))
    }

    private static func serviceMarks(_ row: TelemetryModel.ServiceRow, y: Double) -> String {
        let ink = Freshness.ink(for: row.state, stale: row.isStale).value
        let nameColumn: Double = 128
        let valueColumn: Double = 92
        // The column is reserved whether or not this row has history. Sizing it to the
        // actual data would step every meter left or right by row, and a list of bars that
        // do not share a left edge cannot be compared by eye — which is the only thing the
        // column is for.
        let sparkX = pad + nameColumn
        let meterX = sparkX + SVG.sparklineWidth(count: 12) + 12
        let meterWidth = width - pad - valueColumn - meterX - 12

        var out = SVG.label(
            SVG.truncate(row.name, size: 20, maxWidth: nameColumn - 8),
            x: pad, y: y + 6, size: 20,
            ink: row.state == .nodata ? Ink.absent.value : Ink.primary.value)
        out += SVG.sparkline(row.sparkline, x: sparkX, baseline: y + 8)
        if meterWidth > 20 {
            out += SVG.meter(
                x: meterX, y: y, trackWidth: meterWidth, height: 7,
                utilization: row.utilization, ink: ink)
        }
        out += SVG.label(
            row.display, x: width - pad, y: y + 6, size: 19,
            ink: row.state == .nodata ? Ink.absent.value : Ink.primary.value, anchor: "end")
        return out
    }
}
