#if canImport(AppKit)

import AppKit
import Foundation
import TMUProviders
import XCTest

@testable import TMURender

/// Writes a PNG per layout so a person can look at them.
///
/// Skipped unless `TMU_PREVIEW_DIR` is set, because it is not an assertion — it is the
/// step between "the invariants pass" and "the design is right", and those are different
/// questions. Geometry tests cannot tell you that a column is too narrow or that the
/// quiet card recedes too far; only looking can.
///
///     TMU_PREVIEW_DIR=/tmp/previews swift test --filter PreviewRender
final class PreviewRenderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    func testWritePreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["TMU_PREVIEW_DIR"] else {
            throw XCTSkip("set TMU_PREVIEW_DIR to write preview images")
        }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)

        let cases: [(String, WallpaperLayoutID, [UsageSnapshot])] = [
            ("ledger", .ledger, busy()),
            ("board", .board, busy()),
            ("card-alert", .card, busy()),
            ("card-quiet", .card, calm()),
        ]

        let canvas = WallpaperCanvas(width: 2560, height: 1440)
        for (name, layout, snapshots) in cases {
            let svg = WallpaperSVG.render(
                snapshots, layout: layout, canvas: canvas, generatedAt: now,
                history: history())
            let png = try AppKitRasterizer().compose(
                svg: svg, over: nil, canvas: canvas)
            try png.write(to: root.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: - Fixtures

    private func history() -> [String: [Double]] {
        [
            "vercel": [12, 18, 24, 31, 29, 38, 44, 51, 49, 58, 63, 71],
            "github": [90, 91, 92, 92, 93, 94, 95, 96, 97, 97, 98, 98],
            "twilio": [40, 38, 41, 39, 42, 40, 43, 41, 44, 42, 45, 43],
        ]
    }

    private func busy() -> [UsageSnapshot] {
        [
            account("Claude", 62, "5-hour"),
            account("Claude Two", 96, "5-hour"),
            service("vercel", 71, resetsIn: 3),
            service("github", 98, resetsIn: 18),
            service("twilio", 43, resetsIn: 11),
            service("elevenlabs", 88),
            service("supabase", 34, resetsIn: 28),
            service("openai", 104),
            currency("stripe", 98_000),
            unavailable("sentry"),
            service("posthog", 22),
            service("firecrawl", 67),
            service("resend", 11),
            service("modal", 55),
            service("inngest", 8),
            service("hostinger", 40),
            service("higgsfield", 3),
            service("openart", 17),
            service("mux", 29),
        ]
    }

    private func calm() -> [UsageSnapshot] {
        [account("Claude", 12, "5-hour"), account("Claude Two", 31, "5-hour")]
            + (1...16).map { service("service\($0)", Double($0) * 3) }
    }

    private func account(_ name: String, _ value: Double, _ label: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: "claude", account: name, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "five_hour", kind: .percentOfLimit, value: value, limit: nil,
                    window: .rolling(18000), resetsAt: nil, label: label)
            ])
    }

    private func service(_ name: String, _ value: Double, resetsIn days: Int? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            provider: name, account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "quota", kind: .absolute, value: value, limit: 100,
                    window: .calendarMonth,
                    resetsAt: days.map { now.addingTimeInterval(Double($0) * 86400) })
            ])
    }

    private func currency(_ name: String, _ value: Double) -> UsageSnapshot {
        UsageSnapshot(
            provider: name, account: nil, observedAt: now, status: .ok,
            metrics: [
                Metric(
                    key: "available", kind: .currency, value: value, limit: nil,
                    window: .none, resetsAt: nil)
            ])
    }

    private func unavailable(_ name: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: name, account: nil, observedAt: now,
            status: .unavailable("no public usage API"), metrics: [])
    }
}

#endif
