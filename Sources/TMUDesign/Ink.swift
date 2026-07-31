import Foundation

/// A colour, in the two forms this project needs it.
///
/// The SVG renderer wants the hex string, because colours there are presentation attributes
/// and never a `<style>` block. SwiftUI wants components. Carrying both means neither
/// consumer parses anything at render time, and — more importantly — means this target can
/// hold the palette without importing SwiftUI, so it still builds where AppKit does not.
public struct Hex: Sendable, Equatable {
    public let value: String
    public let red: Double
    public let green: Double
    public let blue: Double

    /// `#rrggbb`. Traps on anything else: these are compile-time literals in this file, so a
    /// malformed one is a typo to fix now, not a condition to handle at runtime.
    public init(_ value: String) {
        precondition(value.count == 7 && value.hasPrefix("#"), "expected #rrggbb, got \(value)")
        let digits = value.dropFirst()
        let number = UInt32(digits, radix: 16)!
        self.value = value
        self.red = Double((number >> 16) & 0xff) / 255
        self.green = Double((number >> 8) & 0xff) / 255
        self.blue = Double(number & 0xff) / 255
    }
}

/// The palette, in one place.
///
/// It was previously three places: a private enum inside the wallpaper renderer, SwiftUI's
/// `.accentColor`/`.orange`/`.red` in the menu bar, and nothing at all on the website. Three
/// surfaces showing the same reading in three different greens is not a style problem — it
/// makes them look like different readings.
///
/// The widget draws its *state* colours from here and its text colour from SwiftUI's
/// semantic `.primary`/`.secondary`. `Ink.primary` is near-white, which is correct on the
/// wallpaper's dark scrim and invisible on a light-mode widget — so the palette kept the
/// meaning and the system took over contrast.
public enum Ink {

    // MARK: - Surfaces

    /// Deep background, behind a panel that has to sit on an arbitrary image.
    ///
    /// Unused by the widget, which gets its background from the widget host's material.
    /// Kept because the website images and the social preview still composite onto it.
    public static let scrim = Hex("#0c1216")
    /// App window background.
    public static let window = Hex("#1e2429")
    /// Window titlebar.
    public static let titlebar = Hex("#262c31")
    /// Menu bar popover background.
    public static let popover = Hex("#1d2226")

    // MARK: - Text

    public static let primary = Hex("#eaf0f2")
    public static let muted = Hex("#8b979e")
    /// For a reading that does not exist — never for a reading of zero.
    public static let absent = Hex("#5b686f")

    // MARK: - State

    public static let ok = Hex("#4e8f78")
    public static let warn = Hex("#e0a24a")
    public static let over = Hex("#e2564a")

    // MARK: - Furniture

    /// Bar tracks and hairlines, always drawn at low opacity rather than as a pale colour,
    /// so they sit correctly on whatever material a widget is placed over.
    public static let track = Hex("#ffffff")
    /// Buttons and toggles.
    public static let action = Hex("#3f6df0")
}

/// Where a reading sits relative to its limit.
///
/// The raw values are load-bearing, and still are — but for a different reason than they
/// were. The wallpaper emitted them as SVG CSS classes (`<g class="row warn">`) and the
/// renderer's tests asserted on those strings. There is no SVG any more.
///
/// What replaced it is `web/widgets.json`, the serialised view models that `check-generated.sh`
/// byte-compares. These strings are keys in that file, so renaming a case still changes a
/// committed artifact and still fails CI. The constraint survived the renderer; only its
/// justification changed. They stay pinned by a test.
public enum UsageState: String, Codable, Sendable, Equatable, CaseIterable {
    case ok
    case warn
    case over
    /// Nothing to report — the provider failed, or has no metrics at all.
    case nodata
    /// A real reading with no ceiling to measure it against.
    ///
    /// Deliberately not folded into `nodata`. A provider reporting revenue has a perfectly
    /// good number and simply no limit; calling that "no data" hides a figure we have.
    case uncapped

    /// Classify a utilisation percentage.
    ///
    /// Only ever returns ok/warn/over. Whether a reading exists at all, and whether it has a
    /// ceiling, are questions the caller has already answered — folding them in here would
    /// collapse the `uncapped`/`nodata` distinction the moment someone passed `nil`.
    public static func classify(utilization: Double) -> UsageState {
        if utilization >= Thresholds.over { return .over }
        if utilization >= Thresholds.warn { return .warn }
        return .ok
    }

    public var ink: Hex {
        switch self {
        case .ok: return Ink.ok
        case .warn: return Ink.warn
        case .over: return Ink.over
        case .nodata: return Ink.absent
        case .uncapped: return Ink.muted
        }
    }
}

/// The numbers that decide what a reading means.
public enum Thresholds {
    /// Warn from here up.
    public static let warn: Double = 80
    /// Nothing left. Readings are never clamped, so 104% renders as 104%.
    public static let over: Double = 100

    /// How old a reading may be before it is *marked* rather than shown as current.
    ///
    /// This is a display rule and only a display rule. Two other horizons exist and are
    /// deliberately different numbers, because they answer different questions:
    ///
    ///   - `Steering.Thresholds.recommendationHorizon` (6h) — is this account recent enough
    ///     to recommend switching to?
    ///   - `UsageMetric.forecastHorizon` (max(1h, window/4)) — is the newest reading close
    ///     enough to fit a slope from?
    ///
    /// Collapsing all three to thirty minutes reads like a simplification and silently
    /// disables every weekly forecast: a weekly metric sampled two hours ago is perfectly
    /// forecastable and would stop being extrapolated.
    public static let staleAfter: TimeInterval = 30 * 60
}
