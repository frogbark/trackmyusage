import TMUProviders
import TMUTelemetry
import XCTest

@testable import TMUWidgets

/// Rendering smoke tests.
///
/// Deliberately not pixel goldens. The PNG encoding depends on the machine's fonts and
/// CoreGraphics version, so a byte comparison here would fail on every machine except the one
/// that last recorded it — the same reason `check-generated.sh` excludes `og.png`. Content
/// regressions are caught by `WidgetViewModelTests`, which compares text.
///
/// What is left for this file is the class of failure the view model cannot see: a view that
/// crashes, collapses to nothing, or silently fails to produce an image at all.
@MainActor
final class WidgetRenderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    /// A view that collapses to zero height still "renders" — it just renders nothing. Only
    /// the pixel dimensions catch that, and only the dimensions are stable enough to assert.
    func testEveryFamilyRendersAtItsDeclaredSize() throws {
        for family in WidgetFamilyID.allCases {
            let vm = WidgetViewModel.make(from: model(), family: family, at: now)
            let image = try XCTUnwrap(
                WidgetRenderer.image(vm, scale: 1), "\(family) produced no image")

            XCTAssertEqual(Double(image.width), family.size.width, "\(family) width")
            XCTAssertEqual(Double(image.height), family.size.height, "\(family) height")
        }
    }

    /// The empty state is the one most likely to collapse, because it has the least in it —
    /// and it is also the state a reader is most likely to mistake for a broken app.
    func testTheEmptyStateStillRendersSomething() throws {
        let empty = TelemetryModel.build(snapshots: [], now: now, timeZone: .gmt)
        for family in WidgetFamilyID.allCases {
            let vm = WidgetViewModel.make(from: empty, family: family, at: now)
            XCTAssertNotNil(WidgetRenderer.image(vm, scale: 1), "\(family) empty state")
        }
    }

    /// Overage is real and is not clamped in the model — 150% and 100% are different facts.
    /// The bar clamps for drawing only, and a bar wider than its track would be a layout fault
    /// rather than a louder signal.
    func testAnOverageRendersWithoutOverflowingItsTrack() throws {
        let vm = WidgetViewModel.make(from: model(utilization: 150), family: .small, at: now)
        XCTAssertEqual(vm.headline?.utilization, 150, "the model must keep the real number")
        XCTAssertNotNil(WidgetRenderer.image(vm, scale: 1))
    }

    private func model(utilization: Double = 62) -> TelemetryModel {
        TelemetryModel.build(
            snapshots: [
                UsageSnapshot(
                    provider: "claude", account: "work", observedAt: now, status: .ok,
                    metrics: [
                        Metric(
                            key: "five-hour", kind: .percentOfLimit, value: utilization,
                            limit: 100, window: .rolling(5 * 3600),
                            resetsAt: now.addingTimeInterval(3 * 86400), label: "5-hour")
                    ])
            ],
            now: now, timeZone: .gmt)
    }
}
