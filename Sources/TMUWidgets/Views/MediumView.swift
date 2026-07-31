import SwiftUI
import TMUDesign

/// 364×170. The account ledger.
///
/// Accounts only. Services are a large-widget concern — this project exists to manage several
/// accounts of one provider, so at this size those are what a reader came for.
struct MediumView: View {
    let model: WidgetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(asOf: model.asOf, isStale: model.isStale)

            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                RowView(row: row, showsWindow: true)
            }

            OverflowNote(count: model.overflow)
            Spacer(minLength: 0)
        }
    }
}
