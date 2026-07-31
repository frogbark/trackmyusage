import SwiftUI
import TMUDesign

/// The widget, at whatever size it was placed.
///
/// Every string here is already final and every state already classified — see the note on
/// `WidgetViewModel`. Nothing in this file or the ones beside it formats a number, compares a
/// threshold or does date arithmetic; that is what keeps `web/widgets.json` an honest
/// description of what gets drawn.
///
/// Text uses SwiftUI's semantic colours rather than the project palette. `Ink.primary` is
/// near-white, which is right on a wallpaper's dark scrim and invisible on a light-mode
/// widget — widgets render on whichever material the viewer's theme supplies. The palette
/// still owns *state* colour, where its meaning lives; the system owns contrast.
public struct UsageWidgetView: View {
    private let model: WidgetViewModel

    public init(_ model: WidgetViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let reason = model.emptyReason {
                EmptyStateView(reason: reason, asOf: model.asOf)
            } else {
                switch model.family {
                case .small: SmallView(model: model)
                case .medium: MediumView(model: model)
                case .large: LargeView(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Nothing to show, said out loud.
///
/// "Absence is stated, never drawn as zero." A blank widget reads as a broken app, and a 0%
/// would be a claim nobody measured.
struct EmptyStateView: View {
    let reason: String
    let asOf: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(asOf: asOf, isStale: false)
            Spacer(minLength: 0)
            Text(reason)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(Ink.absent))
            Spacer(minLength: 0)
        }
    }
}

/// Wordmark and reading time.
///
/// The time is content, not decoration: a widget is looked at precisely when someone wants to
/// know whether the number is current, and the `?` alone does not say *how* old.
struct WidgetHeader: View {
    let asOf: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("USAGE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(asOf)
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isStale ? Color(Ink.muted) : .secondary)
        }
    }
}

/// Name on the left, reading on the right, bar underneath.
///
/// The shape the ledger, the popover and the old wallpaper rail all share, so a reader moving
/// between surfaces is not re-learning the layout each time.
struct RowView: View {
    let row: WidgetViewModel.Row
    var showsWindow: Bool = false
    var showsSparkline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(row.display)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Color(Freshness.ink(for: row.state, stale: row.isStale)))
            }
            if showsWindow, let window = row.windowLabel {
                Text(window)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if showsSparkline {
                Sparkline(values: row.sparkline, state: row.state, isStale: row.isStale)
            }
            Meter(utilization: row.utilization, state: row.state, isStale: row.isStale)
        }
    }
}

/// "+3 more" — truncation, admitted.
struct OverflowNote: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count) more")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}
