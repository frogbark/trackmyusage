import XCTest

@testable import ClaudrupleKit

/// The always-visible string, and the rule for when to interrupt someone.
final class MenuBarSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(
        _ name: String, _ metrics: [UsageMetric: Double], ageMinutes: Double = 1
    ) -> AccountUsage {
        AccountUsage(
            instanceName: name, bundleID: "id.\(name)",
            history: UsageHistory(samples: [
                UsageSample(
                    timestamp: now.addingTimeInterval(-ageMinutes * 60),
                    org: name, metrics: metrics)
            ]))
    }

    // MARK: - Compact title

    func testTitleShowsEveryAccountsBindingPercentage() {
        let s = MenuBarSummary.of(
            accounts: [
                account("Work", [.fiveHour: 61, .sevenDay: 44]),
                account("Personal", [.sevenDay: 100]),
            ], now: now)

        XCTAssertEqual(s.title, "61% · 100%")
    }

    func testTitleOrderFollowsTheAccountsGiven() {
        // Menu bar width is fixed real estate; a title that reorders itself as usage
        // changes is unreadable at a glance.
        let s = MenuBarSummary.of(
            accounts: [account("A", [.fiveHour: 10]), account("B", [.fiveHour: 90])], now: now)
        XCTAssertEqual(s.title, "10% · 90%")
    }

    func testCriticalWhenAnyAccountIsAtItsCap() {
        let s = MenuBarSummary.of(
            accounts: [account("A", [.fiveHour: 10]), account("B", [.sevenDay: 100])], now: now)
        XCTAssertTrue(s.isCritical)
    }

    func testNotCriticalWhenEveryAccountHasRoom() {
        let s = MenuBarSummary.of(
            accounts: [account("A", [.fiveHour: 10]), account("B", [.sevenDay: 44])], now: now)
        XCTAssertFalse(s.isCritical)
    }

    func testStaleAccountsAreMarkedRatherThanShownAsCurrent() {
        // A number with no timestamp beside it reads as live. Showing a two-day-old 12%
        // as "12%" is worse than admitting the reading is old.
        let s = MenuBarSummary.of(
            accounts: [account("A", [.fiveHour: 12], ageMinutes: 60 * 48)], now: now)
        XCTAssertEqual(s.title, "12%?")
    }

    func testNoAccountsYieldsAPlaceholderRatherThanAnEmptyTitle() {
        XCTAssertEqual(MenuBarSummary.of(accounts: [], now: now).title, "—")
    }

    // MARK: - Notification debounce

    func testNotifiesOnCrossingAThreshold() {
        var policy = AlertPolicy(thresholds: [80, 100])
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 82))
    }

    func testDoesNotRepeatWhileStillAboveTheSameThreshold() {
        var policy = AlertPolicy(thresholds: [80, 100])
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 82))
        XCTAssertFalse(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 85))
        XCTAssertFalse(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 99))
    }

    func testNotifiesAgainWhenAHigherThresholdIsCrossed() {
        var policy = AlertPolicy(thresholds: [80, 100])
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 82))
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 100))
    }

    func testReArmsAfterTheWindowResets() {
        // Utilisation falling means the window rolled. The next climb past 80 is a genuinely
        // new event and must be announced, or the second half of the day goes unwarned.
        var policy = AlertPolicy(thresholds: [80, 100])
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 82))
        XCTAssertFalse(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 5))
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 81))
    }

    func testStateIsTrackedPerAccountAndMetric() {
        var policy = AlertPolicy(thresholds: [80])
        XCTAssertTrue(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 82))
        XCTAssertTrue(
            policy.shouldNotify(account: "Personal", metric: .fiveHour, value: 82),
            "a different account is a different event")
        XCTAssertTrue(
            policy.shouldNotify(account: "Work", metric: .sevenDay, value: 82),
            "a different limit on the same account is also a different event")
    }

    func testBelowEveryThresholdNeverNotifies() {
        var policy = AlertPolicy(thresholds: [80, 100])
        XCTAssertFalse(policy.shouldNotify(account: "Work", metric: .fiveHour, value: 79))
    }
}
