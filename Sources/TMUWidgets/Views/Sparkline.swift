import SwiftUI
import TMUDesign

/// Recent readings as a line, or nothing.
///
/// Fewer than two points draws nothing. A single reading rendered as a flat line asserts a
/// trend that was never measured, and this project already refuses to print a forecast it
/// cannot support — the same rule, one surface further on.
struct Sparkline: View {
    let values: [Double]
    let state: UsageState
    let isStale: Bool

    var body: some View {
        if values.count >= 2 {
            GeometryReader { geo in
                path(in: geo.size)
                    .stroke(
                        Color(Freshness.ink(for: state, stale: isStale)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 14)
        }
    }

    private func path(in size: CGSize) -> Path {
        // Scaled to the data's own range rather than to 0–100. A series that moves between
        // 61% and 63% is a flat line on an absolute axis, which hides exactly the movement a
        // sparkline exists to show.
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        let step = values.count > 1 ? size.width / Double(values.count - 1) : 0

        return Path { path in
            for (index, value) in values.enumerated() {
                // A genuinely flat series sits in the middle, not at the bottom: pinning it
                // to y=0 would read as a collapse to zero.
                let ratio = span > 0 ? (value - low) / span : 0.5
                let point = CGPoint(x: Double(index) * step, y: size.height * (1 - ratio))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}
