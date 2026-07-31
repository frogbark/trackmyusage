import Foundation
import TMUTelemetry

/// The demo renders worth producing, one per state the widget has.
///
/// Inherits the deleted DemoWallpaper's job and its reasoning. The images on the website come
/// out of the same code that draws the real widget, so the site cannot show a layout the
/// binary does not produce. A hand-made mockup would be a promise about a design nobody ran
/// — the same mistake this project already refuses for provider adapters, where a parser
/// written from a remembered API shape is indistinguishable from a correct one until it
/// reports the wrong number.
///
/// Two cases rather than the wallpaper's four: the wallpaper had a layout per case, and the
/// widget has a family per size instead, so what is left to vary is the data.
public enum DemoWidget: String, CaseIterable, Sendable {
    /// Something is over its limit. Two accounts and seventeen services.
    case busy
    /// Everything comfortable. What the widget looks like almost all the time.
    case calm

    public func model() -> TelemetryModel {
        TelemetryModel.build(
            snapshots: self == .busy ? DemoSnapshots.busy() : DemoSnapshots.calm(),
            history: DemoSnapshots.history(),
            // Frozen, and load-bearing. `check-generated.sh` byte-compares what this produces,
            // so a render seeded from Date() would emit a new "resets in" figure every run and
            // turn that check into a daily false alarm.
            now: DemoSnapshots.generatedAt,
            timeZone: DemoSnapshots.timeZone)
    }

    public func viewModel(family: WidgetFamilyID) -> WidgetViewModel {
        WidgetViewModel.make(from: model(), family: family, at: DemoSnapshots.generatedAt)
    }

    /// Every family of every case, keyed for a stable JSON dump.
    ///
    /// A sorted dictionary rather than an array so a case inserted later does not renumber
    /// everything after it and produce a diff nobody can read.
    public static func allViewModels() -> [String: WidgetViewModel] {
        var out: [String: WidgetViewModel] = [:]
        for demo in allCases {
            for family in WidgetFamilyID.allCases {
                out["\(demo.rawValue)-\(family.rawValue)"] = demo.viewModel(family: family)
            }
        }
        return out
    }
}
