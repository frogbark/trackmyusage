import AppKit
import Combine
import Foundation
import TMUKit
import UserNotifications

/// Polls every instance's usage history and publishes the current picture.
///
/// Polling rather than watching: Claude rewrites `plan-usage-history.json` about every five
/// minutes, so a 30-second read of a small JSON file is both far more responsive than
/// needed and cheaper than the FSEvents plumbing to notice the write.
@MainActor
final class UsageStore: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let instance: DiscoveredInstance
        let usage: AccountUsage
        let binding: (metric: UsageMetric, value: Double)?
        let forecast: UsageForecast?
        var name: String { instance.name }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var summary = MenuBarSummary(title: "—", isCritical: false)
    @Published private(set) var advice: SteeringAdvice?
    @Published private(set) var activeInstance: String?
    @Published var notificationsEnabled = true

    private var alerts = AlertPolicy()
    private var timer: Timer?

    static let pollInterval: TimeInterval = 30

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let now = Date()

        let loaded: [Row] = InstanceLocator.discover().compactMap { inst in
            let file = inst.profileURL.appendingPathComponent("plan-usage-history.json")
            guard let history = try? UsageHistory.parse(contentsOf: file),
                !history.samples.isEmpty
            else { return nil }

            let usage = AccountUsage(
                instanceName: inst.name, bundleID: inst.bundleID, history: history)
            let binding = usage.binding(now: now)
            return Row(
                id: inst.bundleID,
                instance: inst,
                usage: usage,
                binding: binding,
                forecast: binding.flatMap { history.forecast(for: $0.metric, now: now) })
        }

        rows = loaded
        let accounts = loaded.map(\.usage)
        summary = MenuBarSummary.of(accounts: accounts, now: now)
        activeInstance = Self.inferActive(accounts, now: now)
        advice = Steering.advise(
            accounts: accounts, activeInstance: activeInstance, now: now)

        if notificationsEnabled { notifyIfNeeded(loaded) }
    }

    /// Which account is being worked in.
    ///
    /// `frontmostApplication` would name whichever window has focus, which is routinely a
    /// browser or an editor. The instance whose 5-hour window is climbing fastest is the
    /// one actually consuming budget.
    private static func inferActive(_ accounts: [AccountUsage], now: Date) -> String? {
        accounts
            .compactMap { a -> (String, Double)? in
                guard let f = a.history.forecast(for: .fiveHour, now: now),
                    let rate = f.pointsPerHourOrNil, rate > 0
                else { return nil }
                return (a.instanceName, rate)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func notifyIfNeeded(_ rows: [Row]) {
        for row in rows {
            guard let binding = row.binding else { continue }
            guard
                alerts.shouldNotify(
                    account: row.name, metric: binding.metric, value: binding.value)
            else { continue }

            let content = UNMutableNotificationContent()
            content.title =
                binding.value >= 100
                ? "\(row.name): \(binding.metric.displayName) exhausted"
                : "\(row.name): \(binding.metric.displayName) at \(Int(binding.value))%"

            // Name the alternative in the notification itself. An alert that only reports a
            // problem makes the reader go find the answer; one that carries it is actionable
            // from the lock screen.
            if let target = advice?.recommended, target != row.name {
                content.body = "\(target) has more headroom."
            }
            content.sound = binding.value >= 100 ? .default : nil

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "\(row.id).\(binding.metric.code).\(Int(binding.value))",
                    content: content, trigger: nil))
        }
    }

    func activate(_ instance: DiscoveredInstance) {
        NSWorkspace.shared.open(instance.appURL)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
