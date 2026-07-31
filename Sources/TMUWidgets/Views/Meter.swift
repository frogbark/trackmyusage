import SwiftUI
import TMUDesign

/// The utilisation bar, and the decision not to draw one.
///
/// `utilization` is optional and nil means *draw nothing at all* — not an empty track. A bar
/// is a claim about proximity to a limit, so an uncapped counter or an absent reading has
/// nothing to be a fraction of, and an empty track still asserts "there is a limit, and you
/// are far from it".
struct Meter: View {
    let utilization: Double?
    let state: UsageState
    let isStale: Bool

    var body: some View {
        if let utilization {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(Color(Freshness.ink(for: state, stale: isStale)))
                        // Clamped for *drawing only*. Metric.utilization deliberately does not
                        // clamp, because 150% and 100% are different facts — but a bar wider
                        // than its track is a layout bug rather than a stronger signal.
                        .frame(width: geo.size.width * min(max(utilization, 0), 100) / 100)
                }
            }
            .frame(height: 4)
        }
    }
}
