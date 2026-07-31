import SwiftUI
import TMUDesign

/// 170×170. One reading, large enough to read from across a room.
///
/// The whole widget is its headline. Adding a row list here would put four points of type in
/// 170 points of space and read as neither a summary nor a list — so the small size answers
/// exactly one question, which is what a glance actually asks.
struct SmallView: View {
    let model: WidgetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(asOf: model.asOf, isStale: model.isStale)
            Spacer(minLength: 0)

            if let headline = model.headline {
                Text(headline.display)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(
                        Color(Freshness.ink(for: headline.state, stale: headline.isStale)))

                Text(headline.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)

                if let window = headline.windowLabel {
                    Text(window)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 6)
                Meter(
                    utilization: headline.utilization, state: headline.state,
                    isStale: headline.isStale)
            }
        }
    }
}
