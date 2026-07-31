import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMUAppCore

final class WidgetPublisherTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmu-widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// An ad-hoc build has no App Group, so there is no container and no widget. Publishing
    /// must be a no-op rather than a crash: that build is supported and otherwise complete.
    func testABuildWithNoContainerPublishesNothingRatherThanCrashing() {
        var reloaded = false
        let publisher = WidgetPublisher(url: nil, reload: { reloaded = true })

        XCTAssertFalse(publisher.publish(model()))
        XCTAssertFalse(reloaded)
    }

    func testPublishingWritesAModelTheWidgetCanDecode() throws {
        let url = dir.appendingPathComponent("telemetry.json")
        var reloaded = false
        let publisher = WidgetPublisher(url: url, reload: { reloaded = true })

        XCTAssertTrue(publisher.publish(model()))
        XCTAssertTrue(reloaded)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder().decode(TelemetryModel.self, from: data), model())
    }

    /// rebuild() runs on the 30s instance cadence as well as the 300s provider one, so most
    /// calls carry the bytes already on disk. Waking the extension to redraw an identical
    /// widget spends its reload budget and the user's battery to change nothing.
    func testRepublishingIdenticalContentDoesNotWakeTheWidget() {
        let url = dir.appendingPathComponent("telemetry.json")
        var reloads = 0
        let publisher = WidgetPublisher(url: url, reload: { reloads += 1 })

        XCTAssertTrue(publisher.publish(model()))
        XCTAssertFalse(publisher.publish(model()), "unchanged content must not republish")
        XCTAssertEqual(reloads, 1)
    }

    func testChangedContentDoesWakeTheWidget() {
        let url = dir.appendingPathComponent("telemetry.json")
        var reloads = 0
        let publisher = WidgetPublisher(url: url, reload: { reloads += 1 })

        _ = publisher.publish(model(utilization: 10))
        _ = publisher.publish(model(utilization: 90))
        XCTAssertEqual(reloads, 2)
    }

    private func model(utilization: Double = 62) -> TelemetryModel {
        let at = Date(timeIntervalSince1970: 1_784_000_000)
        return TelemetryModel.build(
            snapshots: [
                UsageSnapshot(
                    provider: "claude", account: "work", observedAt: at, status: .ok,
                    metrics: [
                        Metric(
                            key: "five-hour", kind: .percentOfLimit, value: utilization,
                            limit: 100, window: .rolling(5 * 3600), resetsAt: nil,
                            label: "5-hour")
                    ])
            ],
            now: at, timeZone: .gmt)
    }
}
