import Foundation
import TMUDesign
import TMUTelemetry

/// What the widget shows, and when it changes to showing it.
///
/// Pure, and separate from the WidgetKit provider that consumes it, so the interesting part
/// is testable without a widget host. The provider is a five-line adapter over this.
public enum UsageTimeline {

    public struct Entry: Equatable, Sendable {
        /// When WidgetKit should switch to this entry.
        public let date: Date
        public let model: WidgetViewModel
    }

    /// One read of the container becomes every entry the widget will need.
    ///
    /// The obvious implementation — a single entry, policy `.never` — is wrong, and wrong in
    /// the direction that matters. A widget renders when the system asks it to; if the app
    /// quits, nothing asks again. That one entry was rendered while the data was fresh, so it
    /// carries no `?`, and it would sit on the desktop presenting a frozen number as current
    /// for as long as the widget is placed. "Absence is stated, never drawn as zero" forbids
    /// exactly that.
    ///
    /// So the data is read once and its *ageing* is precomputed: a fresh entry now, and a
    /// second entry dated to the moment the reading crosses the freshness threshold, holding
    /// the same numbers already marked stale. WidgetKit swaps between them on its own clock,
    /// with no reload, no budget spent and no process woken. The widget does not need to be
    /// told its data got old — it works that out when it reads, and says so on schedule.
    ///
    /// Nothing here schedules a *refresh*. Fresh content arrives only when the app publishes
    /// and calls `reloadTimelines`; see `WidgetPublisher` for why that is the right owner.
    public static func entries(
        from model: TelemetryModel,
        family: WidgetFamilyID,
        now: Date
    ) -> [Entry] {
        let goesStaleAt = model.generatedAt.addingTimeInterval(Thresholds.staleAfter)

        let first = Entry(
            date: now, model: WidgetViewModel.make(from: model, family: family, at: now))

        // Already past the threshold when read: the first entry is stale on its own and there
        // is no later transition to schedule.
        guard goesStaleAt > now else { return [first] }

        return [
            first,
            Entry(
                date: goesStaleAt,
                model: WidgetViewModel.make(from: model, family: family, at: goesStaleAt)),
        ]
    }
}
