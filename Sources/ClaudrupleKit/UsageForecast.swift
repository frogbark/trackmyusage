import Foundation

/// A projection of when a usage limit will be reached.
public struct UsageForecast: Sendable, Equatable {
    public let metric: UsageMetric
    /// Latest utilisation, 0–100.
    public let current: Double
    /// Percentage points per hour over the current run. Nil when there is no trend to
    /// measure — one reading is a value, not a trend.
    public let pointsPerHourOrNil: Double?
    /// When utilisation would reach 100 at the current rate. Nil when flat, falling, or
    /// unmeasurable.
    public let exhaustionDate: Date?

    public var pointsPerHour: Double { pointsPerHourOrNil ?? 0 }
    public var isExhausted: Bool { current >= 100 }
}

extension UsageHistory {

    /// Project when `metric` will hit its cap.
    ///
    /// Returns nil when the metric is absent or the newest reading is stale. A forecast
    /// built on old data is worse than no forecast: it is wrong *and* confident.
    /// Windows default to the metric's own timescale; pass `rateWindow` only to override.
    public func forecast(
        for metric: UsageMetric,
        now: Date,
        rateWindow: TimeInterval? = nil
    ) -> UsageForecast? {
        let rateWindow = rateWindow ?? metric.rateWindow
        let readings = samples.compactMap { s -> (Date, Double)? in
            guard let v = s.metrics[metric] else { return nil }
            return (s.timestamp, v)
        }
        guard let latest = readings.last else { return nil }
        guard now.timeIntervalSince(latest.0) <= metric.stalenessLimit else { return nil }

        let run = currentRun(in: readings, notBefore: latest.0.addingTimeInterval(-rateWindow))

        guard let first = run.first, run.count >= 2 else {
            return UsageForecast(
                metric: metric, current: latest.1,
                pointsPerHourOrNil: nil, exhaustionDate: nil)
        }

        let hours = latest.0.timeIntervalSince(first.0) / 3600
        guard hours > 0 else {
            return UsageForecast(
                metric: metric, current: latest.1,
                pointsPerHourOrNil: nil, exhaustionDate: nil)
        }

        let rate = (latest.1 - first.1) / hours
        var exhaustion: Date?
        if rate > 0 && latest.1 < 100 {
            exhaustion = now.addingTimeInterval((100 - latest.1) / rate * 3600)
        }

        return UsageForecast(
            metric: metric, current: latest.1,
            pointsPerHourOrNil: rate, exhaustionDate: exhaustion)
    }

    /// The tail of `readings` since the last reset, bounded by `notBefore`.
    ///
    /// Utilisation only ever rises within a window; a fall means the window rolled. Fitting
    /// a slope across that boundary produces a negative rate and hides an imminent
    /// exhaustion completely — so walk back from the newest reading and stop at the first
    /// drop rather than measuring through it.
    private func currentRun(
        in readings: [(Date, Double)], notBefore cutoff: Date
    ) -> [(Date, Double)] {
        var run: [(Date, Double)] = []
        var previous: Double?

        for reading in readings.reversed() {
            if reading.0 < cutoff { break }
            if let p = previous, reading.1 > p { break }  // walking back: a higher earlier
            run.append(reading)                            // value means a reset followed
            previous = reading.1
        }
        return run.reversed()
    }
}
