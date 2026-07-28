import SwiftUI
import TMUDesign

/// SwiftUI adapts to the palette here, at the consumer.
///
/// The alternative — giving `Hex` a `var color: Color` — would make TMUDesign import
/// SwiftUI, and TMUDesign is deliberately dependency-free so it can be read by the SVG
/// renderer on any platform and, later, by an iOS target. Fifteen lines here buy that.
extension Color {
    init(_ hex: Hex) {
        self.init(.sRGB, red: hex.red, green: hex.green, blue: hex.blue, opacity: 1)
    }
}

extension UsageState {
    /// The colour a reading in this state should be drawn in.
    var color: Color { Color(ink) }
}
