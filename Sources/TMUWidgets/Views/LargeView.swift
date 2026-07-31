import SwiftUI
import TMUDesign

/// 364×364. Accounts, services, sparklines and what renews next.
///
/// The only size with room for the renewal line. It is last because it is the least urgent
/// thing here: a limit you are near matters more than a date that is coming.
struct LargeView: View {
    let model: WidgetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(asOf: model.asOf, isStale: model.isStale)

            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                RowView(row: row, showsWindow: true, showsSparkline: true)
            }

            OverflowNote(count: model.overflow)
            Spacer(minLength: 0)

            if !model.renewals.isEmpty {
                Divider().opacity(0.5)
                ForEach(Array(model.renewals.enumerated()), id: \.offset) { _, renewal in
                    HStack(spacing: 6) {
                        Text(renewal.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(renewal.daysAway)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color(renewal.state.ink))
                    }
                }
            }
        }
    }
}
