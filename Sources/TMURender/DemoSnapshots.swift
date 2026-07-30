import Foundation
import TMUProviders

/// A fixed set of snapshots that exercises every state the wallpaper can draw.
///
/// This exists so the previews, and the images on the website, are produced by the same
/// renderer that draws the real thing. A hand-drawn mockup of a usage panel is a promise
/// about a layout nobody has run — and this project already refuses that bargain for
/// provider adapters, where a parser written from a remembered API shape is
/// indistinguishable from a correct one until it reports the wrong number. A screenshot of
/// a design that was never rendered is the same mistake with a different file extension.
///
/// The data is invented. The drawing is not: `busy()` and `calm()` go through
/// `WallpaperSVG.render` exactly as a live reading would, so a layout that breaks here
/// breaks on the site, visibly, before anyone's desktop sees it.
public enum DemoSnapshots {

    /// The instant every demo render is dated to.
    ///
    /// Frozen, and load-bearing. `generate-web.sh` writes these SVGs into `web/` and
    /// `check-generated.sh` fails when the committed copies differ — so a renderer seeded
    /// from `Date()` would emit a new "resets in" figure on every run and turn that check
    /// into a daily false alarm. Freezing it makes the output a pure function of the code,
    /// which is the only reason the staleness check means anything.
    public static let generatedAt = Date(timeIntervalSince1970: 1_784_000_000)

    /// The zone the frozen instant is drawn in.
    ///
    /// Without this the instant alone is not enough — `Format.time` used to read the
    /// machine's zone, so the same demo drew 20:33 in California and 03:33 on a UTC runner
    /// and `check-generated.sh` failed for a reason no commit could fix.
    public static let timeZone = TimeZone(identifier: "UTC") ?? .gmt

    // MARK: - Sets

    /// Two accounts and seventeen services, with something wrong in most of the ways it can be.
    ///
    /// Deliberately crowded: one account nearly spent, a service over its limit, a currency
    /// meter, and a provider with no public usage API at all. The rail has to stay legible
    /// at this density or it does not scale to a real stack.
    public static func busy() -> [UsageSnapshot] {
        [
            account("Claude", 62, "5-hour"),
            account("Claude Two", 96, "5-hour"),
            service("vercel", 71, resetsIn: 3),
            service("github", 98, resetsIn: 18),
            service("twilio", 43, resetsIn: 11),
            service("elevenlabs", 88),
            service("supabase", 34, resetsIn: 28),
            service("openai", 104),
            currency("stripe", 98_000),
            unavailable("sentry"),
            service("posthog", 22),
            service("firecrawl", 67),
            service("resend", 11),
            service("modal", 55),
            service("inngest", 8),
            service("hostinger", 40),
            service("higgsfield", 3),
            service("openart", 17),
            service("mux", 29),
        ]
    }

    /// The same stack on a day when nothing needs attention.
    ///
    /// Everything under 80%, which is the threshold at which the card stops enumerating and
    /// dims to a whisper. Rendering this beside `busy()` is the only way to see that the
    /// quiet state recedes far enough to be worth having.
    public static func calm() -> [UsageSnapshot] {
        [
            account("Claude", 12, "5-hour"),
            account("Claude Two", 31, "5-hour"),
            service("vercel", 18, resetsIn: 12),
            service("github", 24, resetsIn: 21),
            service("twilio", 9, resetsIn: 6),
            service("elevenlabs", 33),
            service("supabase", 15, resetsIn: 28),
            service("openai", 41),
            currency("stripe", 124_000),
            service("posthog", 7),
            service("firecrawl", 29),
            service("resend", 4),
            service("modal", 22),
            service("inngest", 3),
            service("hostinger", 36),
            service("sentry", 19),
            service("mux", 11),
        ]
    }

    /// Twelve readings per provider, for the sparklines.
    ///
    /// Three distinct shapes on purpose — climbing, saturated, and flat — because a
    /// sparkline that renders one of them well can still be unreadable for the others.
    public static func history() -> [String: [Double]] {
        [
            "vercel": [12, 18, 24, 31, 29, 38, 44, 51, 49, 58, 63, 71],
            "github": [90, 91, 92, 92, 93, 94, 95, 96, 97, 97, 98, 98],
            "twilio": [40, 38, 41, 39, 42, 40, 43, 41, 44, 42, 45, 43],
        ]
    }

    // MARK: - Builders

    private static func account(_ name: String, _ value: Double, _ label: String)
        -> UsageSnapshot
    {
        UsageSnapshot(
            provider: "claude", account: name, observedAt: generatedAt, status: .ok,
            metrics: [
                Metric(
                    key: "five_hour", kind: .percentOfLimit, value: value, limit: nil,
                    window: .rolling(18000), resetsAt: nil, label: label)
            ])
    }

    private static func service(_ name: String, _ value: Double, resetsIn days: Int? = nil)
        -> UsageSnapshot
    {
        UsageSnapshot(
            provider: name, account: nil, observedAt: generatedAt, status: .ok,
            metrics: [
                Metric(
                    key: "quota", kind: .absolute, value: value, limit: 100,
                    window: .calendarMonth,
                    resetsAt: days.map {
                        generatedAt.addingTimeInterval(Double($0) * 86400)
                    })
            ])
    }

    private static func currency(_ name: String, _ value: Double) -> UsageSnapshot {
        UsageSnapshot(
            provider: name, account: nil, observedAt: generatedAt, status: .ok,
            metrics: [
                Metric(
                    key: "available", kind: .currency, value: value, limit: nil,
                    window: .none, resetsAt: nil)
            ])
    }

    private static func unavailable(_ name: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: name, account: nil, observedAt: generatedAt,
            status: .unavailable("no public usage API"), metrics: [])
    }
}

/// The demo renders worth producing: one per layout, plus both faces of the card.
///
/// Named as a type rather than written out at each call site because two of them exist —
/// the preview PNGs a person eyeballs, and the SVGs the website ships — and a case added to
/// one list but not the other is a layout that goes to production having been looked at by
/// nobody.
public enum DemoWallpaper: String, CaseIterable, Sendable {
    case ledger
    case board
    /// The card with something hot: it grows, brightens and leads with the offender.
    case cardAlert = "card-alert"
    /// The same card when everything is under 80% and there is nothing to say.
    case cardQuiet = "card-quiet"

    public var layout: WallpaperLayoutID {
        switch self {
        case .ledger: return .ledger
        case .board: return .board
        case .cardAlert, .cardQuiet: return .card
        }
    }

    public var snapshots: [UsageSnapshot] {
        switch self {
        case .cardQuiet: return DemoSnapshots.calm()
        case .ledger, .board, .cardAlert: return DemoSnapshots.busy()
        }
    }

    /// Render this case at the given canvas, dated to the frozen demo instant.
    ///
    /// UTC, stated here rather than exported before running the generator. A frozen instant
    /// is only half of reproducibility: the panel draws a clock, so the zone it is read in
    /// is an input too, and leaving that to the machine is what made the committed images
    /// disagree with the ones CI produced.
    public func svg(canvas: WallpaperCanvas = .default) -> String {
        WallpaperSVG.render(
            snapshots, layout: layout, canvas: canvas,
            generatedAt: DemoSnapshots.generatedAt, history: DemoSnapshots.history(),
            timeZone: DemoSnapshots.timeZone)
    }
}
