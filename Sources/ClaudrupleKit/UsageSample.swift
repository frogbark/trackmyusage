import Foundation

/// A plan-usage dimension.
///
/// Codes come from the app bundle's own map:
///
///     {five_hour:"fh", seven_day:"sd", seven_day_opus:"so", seven_day_oauth_apps:"oa",
///      seven_day_cowork:"cw", seven_day_omelette:"om", omelette_promotional:"op",
///      seven_day_sonnet:"sn"}
///
/// plus a separate `"xu"` for extra usage. Values are `utilization` percentages (0–100)
/// lifted from the plan-usage API response — the app's own accounting, not an estimate
/// reconstructed from token logs.
public enum UsageMetric: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case sevenDayCowork
    case sevenDayOAuthApps
    case sevenDayOmelette
    case omellettePromotional
    /// Pay-as-you-go credit pool. Sits outside the limit map because it is not a limit,
    /// which is also why its values are fractional where limits are integral.
    case extraUsage
    /// A code this build does not recognise.
    ///
    /// Not a defensive nicety: `xu` shipped without appearing in the limit map, and the
    /// same will happen again. Dropping unrecognised codes would hide a new limit at
    /// exactly the moment a usage tool most needs to show it.
    case unknown(String)

    public static let known: [UsageMetric] = [
        .fiveHour, .sevenDay, .sevenDayOpus, .sevenDaySonnet, .sevenDayCowork,
        .sevenDayOAuthApps, .sevenDayOmelette, .omellettePromotional, .extraUsage,
    ]

    private static let codes: [UsageMetric: String] = [
        .fiveHour: "fh", .sevenDay: "sd", .sevenDayOpus: "so", .sevenDaySonnet: "sn",
        .sevenDayCowork: "cw", .sevenDayOAuthApps: "oa", .sevenDayOmelette: "om",
        .omellettePromotional: "op", .extraUsage: "xu",
    ]

    public init(code: String) {
        self = Self.codes.first { $0.value == code }?.key ?? .unknown(code)
    }

    public var code: String {
        if case .unknown(let raw) = self { return raw }
        return Self.codes[self] ?? "?"
    }

    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "Weekly"
        case .sevenDayOpus: return "Weekly (Opus)"
        case .sevenDaySonnet: return "Weekly (Sonnet)"
        case .sevenDayCowork: return "Weekly (Cowork)"
        case .sevenDayOAuthApps: return "Weekly (OAuth apps)"
        case .sevenDayOmelette: return "Weekly (Omelette)"
        case .omellettePromotional: return "Omelette (promo)"
        case .extraUsage: return "Extra usage"
        case .unknown(let raw): return raw
        }
    }

    /// The window each metric resets over. Drives burn-rate forecasting.
    public var window: TimeInterval? {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet, .sevenDayCowork,
             .sevenDayOAuthApps, .sevenDayOmelette, .omellettePromotional:
            return 7 * 24 * 3600
        case .extraUsage, .unknown: return nil
        }
    }

    /// How far back to look when measuring a rate.
    ///
    /// Scaled to the metric's own period rather than fixed. A single window cannot serve
    /// both: two hours is a generous sample of a 5-hour window but a rounding error
    /// against a weekly one, where it would read as flat and forecast "never".
    public var rateWindow: TimeInterval {
        guard let window else { return 2 * 3600 }
        return max(1800, window / 5)  // 5h -> 1h, 7d -> ~34h
    }

    /// Beyond this, the newest reading is too old to extrapolate from.
    ///
    /// Also scaled: the app samples only while running, so history has holes — one of ten
    /// days on the development machine. Three hours of silence says little about a weekly
    /// cap and almost everything about a 5-hour one.
    public var stalenessLimit: TimeInterval {
        guard let window else { return 3 * 3600 }
        return max(3600, window / 4)  // 5h -> 1.25h, 7d -> 42h
    }
}

/// One observation, roughly every five minutes while the app runs.
public struct UsageSample: Sendable, Equatable {
    public let timestamp: Date
    /// Organisation UUID. Nil in legacy v1 files, which predate the field.
    public let org: String?
    public let metrics: [UsageMetric: Double]

    public init(timestamp: Date, org: String?, metrics: [UsageMetric: Double]) {
        self.timestamp = timestamp
        self.org = org
        self.metrics = metrics
    }
}

public enum UsageError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let detail): return "could not read usage history: \(detail)"
        }
    }
}

/// A parsed `plan-usage-history.json`.
public struct UsageHistory: Sendable, Equatable {
    /// Chronological.
    public let samples: [UsageSample]

    public init(samples: [UsageSample]) { self.samples = samples }

    public static func parse(_ json: String) throws -> UsageHistory {
        guard let data = json.data(using: .utf8) else {
            throw UsageError.unreadable("not valid UTF-8")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> UsageHistory {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["samples"] as? [[String: Any]]
        else { throw UsageError.unreadable("expected an object with a `samples` array") }

        let version = root["version"] as? Int ?? 2
        let samples = raw.compactMap { entry -> UsageSample? in
            guard let t = entry["t"] as? Double else { return nil }
            return UsageSample(
                timestamp: Date(timeIntervalSince1970: t / 1000),
                org: entry["org"] as? String,
                metrics: version == 1 ? flatMetrics(entry) : nestedMetrics(entry))
        }
        // Written append-only, but sorting makes ordering a guarantee rather than a
        // hope — every consumer downstream assumes chronological order.
        return UsageHistory(samples: samples.sorted { $0.timestamp < $1.timestamp })
    }

    public static func parse(contentsOf url: URL) throws -> UsageHistory {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return UsageHistory(samples: [])  // no history yet is not a failure
        }
        return try parse(data)
    }

    /// v2: `{t, org, u: {code: value}}`
    private static func nestedMetrics(_ entry: [String: Any]) -> [UsageMetric: Double] {
        guard let u = entry["u"] as? [String: Any] else { return [:] }
        var out: [UsageMetric: Double] = [:]
        for (code, value) in u {
            // NSNull for an explicitly null reading: absent, not zero.
            guard let n = value as? Double else { continue }
            out[UsageMetric(code: code)] = n
        }
        return out
    }

    /// v1: `{t, fh, sd}` with nullable fields and no org.
    private static func flatMetrics(_ entry: [String: Any]) -> [UsageMetric: Double] {
        var out: [UsageMetric: Double] = [:]
        for code in ["fh", "sd"] {
            if let n = entry[code] as? Double { out[UsageMetric(code: code)] = n }
        }
        return out
    }
}
