import Foundation
import TMUDesign
import TMUTelemetry

/// Which of the three widget sizes is being drawn.
///
/// Its own type rather than WidgetKit's `WidgetFamily` so this target does not import
/// WidgetKit — see the note on the target in Package.swift. The extension maps one to the
/// other in a single switch.
public enum WidgetFamilyID: String, Codable, Equatable, Sendable, CaseIterable {
    case small
    case medium
    case large

    /// How many rows this size can carry without becoming unreadable.
    ///
    /// A number rather than "as many as fit" because a widget that reflows its row count with
    /// the data is a widget whose layout cannot be golden-tested. Anything beyond the budget
    /// is reported as overflow, never silently dropped.
    var rowBudget: Int {
        switch self {
        case .small: return 0  // the headline is the whole widget
        case .medium: return 3
        case .large: return 6
        }
    }

    /// Nominal size in points, used by the CLI and the snapshot tests.
    public var size: (width: Double, height: Double) {
        switch self {
        case .small: return (170, 170)
        case .medium: return (364, 170)
        case .large: return (364, 364)
        }
    }
}

/// Everything the widget draws, decided before any view exists.
///
/// This is the pure, text-comparable artifact the wallpaper's SVG string used to be. That
/// mattered more than it looks: `check-generated.sh` can byte-compare text and cannot
/// byte-compare a CoreGraphics raster, because the encoding depends on the machine's fonts
/// and CoreGraphics version rather than on anything in this repository. Serialising *this*
/// into web/widgets.json is what keeps a layout regression a failing diff rather than
/// something somebody notices on a desktop three weeks later.
///
/// So the rule the views must obey: **no formatting, no threshold comparison and no date
/// arithmetic in a SwiftUI view.** Every string here is final, every state already
/// classified. A view that computes something is a view whose output the goldens do not
/// describe.
public struct WidgetViewModel: Codable, Equatable, Sendable {

    /// One reading, ready to draw.
    public struct Row: Codable, Equatable, Sendable {
        public let name: String
        /// Final text, `?` already applied where the reading is stale.
        public let display: String
        public let state: UsageState
        public let isStale: Bool
        /// 0–100, or nil when this reading has no ceiling to be a fraction of.
        ///
        /// nil means *draw no bar*. A bar is a claim about proximity to a limit, and an
        /// uncapped or absent reading has no limit to be near.
        public let utilization: Double?
        /// "5-hour", "Weekly" — what the percentage is a percentage of.
        public let windowLabel: String?
        /// Recent readings, oldest first. Fewer than two means draw nothing: a single point
        /// rendered as a flat line asserts a trend that was never measured.
        public let sparkline: [Double]
    }

    public struct RenewalLine: Codable, Equatable, Sendable {
        public let name: String
        /// "3d", "today" — already formatted.
        public let daysAway: String
        public let state: UsageState
    }

    public let family: WidgetFamilyID
    /// The one reading that most wants attention, or nil when there is nothing to show.
    public let headline: Row?
    public let rows: [Row]
    /// Readings that did not fit. Stated in the view, never silently dropped — a widget
    /// showing three of nine accounts while looking like it shows all of them is worse than
    /// one that admits the truncation.
    public let overflow: Int
    public let renewals: [RenewalLine]
    public let attention: TelemetryModel.Attention
    /// The reading time, in the model's own zone. "20:33".
    public let asOf: String
    /// The published data itself went stale — the app stopped writing.
    ///
    /// Distinct from a row being stale, which means one provider stopped answering. This one
    /// means nothing here is current, and every row is marked accordingly.
    public let isStale: Bool
    /// Why there is nothing to draw, when there is nothing to draw.
    ///
    /// Never an empty widget and never a zero. "Absence is stated, never drawn as zero" is
    /// the project's rule and a blank panel reads as a broken app rather than as no data.
    public let emptyReason: String?

    // MARK: - Building

    /// The single point where the shared model becomes widget content.
    ///
    /// `at` is the moment being drawn *for*, not the moment this runs. The timeline builds
    /// several entries from one read by calling this with future dates, so a widget whose
    /// publisher has stopped ages into its stale state on the system's clock without ever
    /// waking this process. Staleness therefore has to be a function of the arguments and
    /// nothing else.
    public static func make(
        from model: TelemetryModel,
        family: WidgetFamilyID,
        at date: Date
    ) -> WidgetViewModel {

        let publishedAge = date.timeIntervalSince(model.generatedAt)
        let stale = Freshness.isStale(age: publishedAge)

        let accounts = model.claude.map { Row(account: $0, containerStale: stale) }
        let services = model.services.map { Row(service: $0, containerStale: stale) }
        let everything = accounts + services

        let headline = mostUrgent(of: everything)

        let candidates: [Row]
        switch family {
        case .small:
            candidates = []
        case .medium:
            // The account ledger. Services are a large-widget concern: a medium showing both
            // gets four points of type at 170pt tall and reads as neither.
            candidates = accounts
        case .large:
            candidates = everything
        }

        let shown = Array(candidates.prefix(family.rowBudget))
        let overflow = candidates.count - shown.count

        let renewals =
            family == .large
            ? model.renewals.prefix(3).map {
                RenewalLine(
                    name: $0.name, daysAway: Format.daysAway($0.daysAway), state: $0.state)
            }
            : []

        return WidgetViewModel(
            family: family,
            headline: headline,
            rows: shown,
            overflow: overflow,
            renewals: Array(renewals),
            attention: model.attention,
            asOf: Format.time(model.generatedAt, in: model.timeZone),
            isStale: stale,
            emptyReason: everything.isEmpty ? "no data" : nil)
    }

    /// The reading a glance should land on.
    ///
    /// Highest utilisation wins. Readings without a utilisation cannot be ranked against ones
    /// that have it — an uncapped counter is not "less urgent" than 12%, it is not on the
    /// scale at all — so they are only chosen when nothing measurable exists, and then in the
    /// model's existing stable order rather than by inventing one.
    private static func mostUrgent(of rows: [Row]) -> Row? {
        let measurable = rows.filter { $0.utilization != nil }
        if let peak = measurable.max(by: { ($0.utilization ?? 0) < ($1.utilization ?? 0) }) {
            return peak
        }
        return rows.first
    }
}

extension WidgetViewModel.Row {

    /// Marking is conditional because `display` already carries its own `?` when the provider
    /// itself went quiet. Calling `Freshness.mark` unconditionally on a row that is already
    /// marked produces "62%??", which reads as a rendering bug rather than as staleness.
    fileprivate static func display(_ text: String, rowStale: Bool, containerStale: Bool)
        -> String
    {
        rowStale ? text : Freshness.mark(text, stale: containerStale)
    }

    fileprivate init(account: TelemetryModel.AccountRow, containerStale: Bool) {
        self.init(
            name: account.name,
            display: Self.display(
                account.display, rowStale: account.isStale, containerStale: containerStale),
            state: account.state,
            isStale: account.isStale || containerStale,
            utilization: account.utilization,
            windowLabel: account.windowLabel,
            sparkline: [])
    }

    fileprivate init(service: TelemetryModel.ServiceRow, containerStale: Bool) {
        self.init(
            name: service.name,
            display: Self.display(
                service.display, rowStale: service.isStale, containerStale: containerStale),
            state: service.state,
            isStale: service.isStale || containerStale,
            utilization: service.utilization,
            windowLabel: nil,
            sparkline: service.sparkline)
    }
}
