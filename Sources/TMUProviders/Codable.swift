import Foundation

/// Persistence for the snapshot types.
///
/// Kept in its own file rather than spelled out at each declaration, because the shapes here
/// exist to serve the disk cache and the golden files — not to describe the domain — and
/// mixing the two makes the domain types harder to read than they need to be.
///
/// Two of these have associated values, so the synthesised conformance is not available and
/// the encoding is chosen deliberately. Both are written as a tagged object rather than
/// Swift's default nested-key form, so a human reading the cache file can tell what it says.

extension MetricKind: Codable {
    // A raw-value enum would have been simpler, but this type is switched over exhaustively
    // in five places and adding a raw value invites someone to persist it somewhere the
    // exhaustiveness check cannot see.
    private enum Name: String, Codable {
        case percentOfLimit, absolute, currency, count
    }

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(Name.self) {
        case .percentOfLimit: self = .percentOfLimit
        case .absolute: self = .absolute
        case .currency: self = .currency
        case .count: self = .count
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .percentOfLimit: try container.encode(Name.percentOfLimit)
        case .absolute: try container.encode(Name.absolute)
        case .currency: try container.encode(Name.currency)
        case .count: try container.encode(Name.count)
        }
    }
}

extension MetricWindow: Codable {
    private enum Key: String, CodingKey { case kind, seconds }
    private enum Kind: String, Codable { case rolling, calendarMonth, billingPeriod, none }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .rolling: self = .rolling(try container.decode(TimeInterval.self, forKey: .seconds))
        case .calendarMonth: self = .calendarMonth
        case .billingPeriod: self = .billingPeriod
        case .none: self = .none
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .rolling(let seconds):
            try container.encode(Kind.rolling, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .calendarMonth: try container.encode(Kind.calendarMonth, forKey: .kind)
        case .billingPeriod: try container.encode(Kind.billingPeriod, forKey: .kind)
        case .none: try container.encode(Kind.none, forKey: .kind)
        }
    }
}

extension UsageSnapshot.Status: Codable {
    private enum Key: String, CodingKey { case kind, reason }
    private enum Kind: String, Codable { case ok, unavailable, unauthorized }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ok: self = .ok
        case .unauthorized: self = .unauthorized
        case .unavailable:
            // The reason is what the UI shows instead of a number, so losing it would turn
            // a specific failure into a blank one.
            self = .unavailable(try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .ok: try container.encode(Kind.ok, forKey: .kind)
        case .unauthorized: try container.encode(Kind.unauthorized, forKey: .kind)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

extension Metric: Codable {
    private enum Key: String, CodingKey {
        case key, label, kind, value, limit, unit, window, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            kind: try container.decode(MetricKind.self, forKey: .kind),
            value: try container.decode(Double.self, forKey: .value),
            limit: try container.decodeIfPresent(Double.self, forKey: .limit),
            window: try container.decode(MetricWindow.self, forKey: .window),
            resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            unit: try container.decodeIfPresent(String.self, forKey: .unit))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encode(window, forKey: .window)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }
}

extension UsageSnapshot: Codable {
    private enum Key: String, CodingKey { case provider, account, observedAt, status, metrics }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            provider: try container.decode(String.self, forKey: .provider),
            account: try container.decodeIfPresent(String.self, forKey: .account),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            status: try container.decode(Status.self, forKey: .status),
            metrics: try container.decode([Metric].self, forKey: .metrics))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(account, forKey: .account)
        // observedAt is the whole point of caching these: it is what lets a restored
        // snapshot be marked stale rather than presented as current.
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(status, forKey: .status)
        try container.encode(metrics, forKey: .metrics)
    }
}
