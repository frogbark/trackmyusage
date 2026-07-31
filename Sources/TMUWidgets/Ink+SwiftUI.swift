import SwiftUI
import TMUDesign

/// SwiftUI adapts to the palette here, at the consumer.
///
/// The alternative — giving `Hex` a `var color: Color` — would make TMUDesign import SwiftUI,
/// and TMUDesign is deliberately dependency-free so it stays buildable on Linux, which CI
/// proves on every push. Fifteen lines here buy that.
///
/// It lives in TMUWidgets rather than in the app because both surfaces need it and this is
/// the lower of the two. Public for that reason, not because anything outside should adopt
/// the palette this way.
extension Color {
    public init(_ hex: Hex) {
        self.init(.sRGB, red: hex.red, green: hex.green, blue: hex.blue, opacity: 1)
    }
}

extension UsageState {
    /// The colour a reading in this state should be drawn in.
    public var color: Color { Color(ink) }
}
