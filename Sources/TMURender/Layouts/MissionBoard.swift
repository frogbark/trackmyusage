import Foundation
import TMUDesign
import TMUTelemetry

/// 1e — the mission board. Tiles across the bottom of a wide desktop.
///
/// The rail is a list; this is a board. Same information, laid out so a glance takes in the
/// whole stack at once rather than reading downward. It needs real width — 1656 design units
/// — and `WallpaperSVG` falls back to the rail when the canvas cannot give it that, rather
/// than compressing the tiles into illegibility.
enum MissionBoard: Sendable {

    static let x: Double = 96
    static let bottomMargin: Double = 130
    static let width: Double = 1560

    /// Below this the tiles stop being readable and the rail is the better answer.
    static let minimumDesignWidth: Double = 1656

    static func render(_ model: TelemetryModel, designHeight: Double) -> String {
        let headerHeight: Double = 46
        let accountTile = (w: 350.0, h: 230.0)
        let gutter: Double = 20

        let serviceColumns = 4
        let serviceRows = Int(
            (Double(model.services.count) / Double(serviceColumns)).rounded(.up))
        let serviceTile = (w: 0.0, h: 74.0)  // width computed below from the space left over

        let accountsWidth =
            Double(model.claude.count) * accountTile.w
            + Double(max(model.claude.count - 1, 0)) * gutter
        let gridX = accountsWidth + (model.claude.isEmpty ? 0 : gutter)
        let gridWidth = width - gridX
        let tileWidth =
            (gridWidth - Double(serviceColumns - 1) * gutter) / Double(serviceColumns)

        let gridHeight =
            Double(serviceRows) * serviceTile.h + Double(max(serviceRows - 1, 0)) * gutter
        let bodyHeight = max(accountTile.h, gridHeight)
        let renewalHeight: Double = model.renewals.isEmpty ? 0 : 34
        let height = headerHeight + bodyHeight + renewalHeight

        var out = SVG.group(x: x, y: designHeight - height - bottomMargin)
        out += SVG.wordmark(x: 0, y: 14)
        out += SVG.label(
            Format.time(model.generatedAt), x: width, y: 14, size: 19,
            ink: Ink.muted.value, anchor: "end")

        for (index, account) in model.claude.enumerated() {
            out += accountTileView(
                account,
                x: Double(index) * (accountTile.w + gutter),
                y: headerHeight,
                width: accountTile.w,
                height: accountTile.h)
        }

        for (index, service) in model.services.enumerated() {
            let column = index % serviceColumns
            let row = index / serviceColumns
            out += serviceTileView(
                service,
                x: gridX + Double(column) * (tileWidth + gutter),
                y: headerHeight + Double(row) * (serviceTile.h + gutter),
                width: tileWidth,
                height: serviceTile.h)
        }

        if !model.renewals.isEmpty {
            out += SVG.renewalLine(
                model.renewals, x: 0, y: headerHeight + bodyHeight + 24, width: width,
                limit: 4)
        }
        return out + "</g>"
    }

    private static func accountTileView(
        _ row: TelemetryModel.AccountRow, x: Double, y: Double, width: Double, height: Double
    ) -> String {
        let pad: Double = 26
        let ink = Freshness.ink(for: row.state, stale: row.isStale).value

        var out = SVG.group(x: x, y: y) + "<g class=\"row \(row.state.rawValue)\">"
        out += SVG.panel(width: width, height: height, radius: 20, opacity: 0.60)
        out += SVG.label(
            SVG.truncate(row.name, size: 22, maxWidth: width - pad * 2),
            x: pad, y: pad + 14, size: 22, ink: Ink.primary.value, weight: 600)
        out += SVG.label(
            row.display, x: pad, y: pad + 92, size: 62, ink: ink, weight: 700)
        out += SVG.meter(
            x: pad, y: pad + 112, trackWidth: width - pad * 2, height: 9,
            utilization: row.utilization, ink: ink)
        if let window = row.windowLabel {
            out += SVG.label(
                window, x: pad, y: pad + 152, size: 17, ink: Ink.muted.value)
        }
        return out + "</g></g>"
    }

    private static func serviceTileView(
        _ row: TelemetryModel.ServiceRow, x: Double, y: Double, width: Double, height: Double
    ) -> String {
        let padX: Double = 18
        let padY: Double = 16
        let ink = Freshness.ink(for: row.state, stale: row.isStale).value
        let text = row.state == .nodata ? Ink.absent.value : Ink.primary.value

        var out = SVG.group(x: x, y: y) + "<g class=\"row \(row.state.rawValue)\">"
        out += SVG.panel(width: width, height: height, radius: 14, opacity: 0.55)
        // Name and value share a line: the tile is small, and stacking them would push the
        // meter off the bottom or shrink the value to the point of needing a second look.
        // Reserve what the value actually measures, not a fixed 80pt. A flat reservation
        // sized for "$98,000" truncates every name on a tile showing "3%", which is most of
        // them — the grid went out reading "eleven…", "higgsf…", "supaba…".
        let valueWidth = SVG.estimateWidth(row.display, size: 19)
        out += SVG.label(
            SVG.truncate(row.name, size: 17, maxWidth: width - padX * 2 - valueWidth - 14),
            x: padX, y: padY + 12, size: 17, ink: text)
        out += SVG.label(
            row.display, x: width - padX, y: padY + 12, size: 19, ink: text, anchor: "end")
        out += SVG.meter(
            x: padX, y: padY + 28, trackWidth: width - padX * 2, height: 6,
            utilization: row.utilization, ink: ink)
        return out + "</g></g>"
    }
}
