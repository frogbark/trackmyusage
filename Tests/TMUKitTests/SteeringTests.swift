import XCTest

@testable import TMUKit

/// Deciding which account to work in.
///
/// The valuable half of this is restraint. A tool that suggests switching accounts every
/// few minutes gets muted, and a muted tool cannot warn you about anything — so most of
/// these tests pin down when it must stay quiet.
final class SteeringTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(
        _ name: String, _ metrics: [UsageMetric: Double], ageMinutes: Double = 1
    ) -> AccountUsage {
        AccountUsage(
            instanceName: name,
            bundleID: "com.anthropic.claudefordesktop.claudruple.\(name.lowercased())",
            history: UsageHistory(samples: [
                UsageSample(
                    timestamp: now.addingTimeInterval(-ageMinutes * 60),
                    org: name, metrics: metrics)
            ]))
    }

    // MARK: - Binding constraint

    func testBindingConstraintIsTheLimitClosestToItsCap() {
        // 5-hour at 95 blocks work even though the weekly cap is nearly untouched.
        let a = account("Work", [.fiveHour: 95, .sevenDay: 10])
        XCTAssertEqual(a.binding(now: now)?.metric, .fiveHour)
        XCTAssertEqual(a.binding(now: now)?.value, 95)
    }

    func testExtraUsageIsNotABindingLimit() {
        // extra_usage is a pay-as-you-go credit pool, not a cap — running it up does not
        // block work the way a limit does, so it must not drive a switch recommendation.
        let a = account("Work", [.fiveHour: 20, .extraUsage: 99])
        XCTAssertEqual(a.binding(now: now)?.metric, .fiveHour)
    }

    func testUnknownMetricsAreNotBindingLimits() {
        // A code this build does not recognise is shown to the user, but its semantics are
        // unknown — treating it as a cap would let a future field trigger false advice.
        let a = account("Work", [.fiveHour: 20, .unknown("zz"): 99])
        XCTAssertEqual(a.binding(now: now)?.metric, .fiveHour)
    }

    func testHeadroomIsMeasuredAgainstTheBindingLimit() {
        XCTAssertEqual(account("Work", [.fiveHour: 61, .sevenDay: 44]).headroom(now: now), 39)
    }

    // MARK: - Recommending a switch

    func testExhaustedAccountIsSteeredToOneWithHeadroom() {
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.sevenDay: 100, .fiveHour: 0]),
                account("Second", [.fiveHour: 61, .sevenDay: 44]),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertEqual(advice.urgency, .exhausted)
        XCTAssertEqual(advice.recommended, "Second")
        XCTAssertEqual(advice.bindingMetric, .sevenDay)
    }

    func testApproachingTheLimitIsFlaggedBeforeItIsHit() {
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.fiveHour: 85]),
                account("Second", [.fiveHour: 10]),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertEqual(advice.urgency, .approaching)
        XCTAssertEqual(advice.recommended, "Second")
    }

    // MARK: - Staying quiet

    func testHealthyAccountGetsNoRecommendation() {
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.fiveHour: 20]),
                account("Second", [.fiveHour: 10]),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertEqual(advice.urgency, .none)
        XCTAssertNil(advice.recommended, "10 points of advantage is not worth moving for")
    }

    func testMarginalAdvantageDoesNotTriggerASwitch() {
        // 82 -> 78 is not worth abandoning a session over. Without a margin the tool would
        // oscillate between two accounts that are both nearly full.
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.fiveHour: 82]),
                account("Second", [.fiveHour: 78]),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertEqual(advice.urgency, .approaching, "the warning still stands")
        XCTAssertNil(advice.recommended, "but there is nowhere meaningfully better to go")
    }

    func testNoRecommendationWhenEveryAccountIsExhausted() {
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.sevenDay: 100]),
                account("Second", [.sevenDay: 100]),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertEqual(advice.urgency, .exhausted)
        XCTAssertNil(advice.recommended)
    }

    func testStaleAccountsAreNotRecommended() {
        // An account last seen two days ago may have been consumed since. Steering someone
        // toward it on the strength of an old reading is worse than saying nothing.
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.fiveHour: 95]),
                account("Second", [.fiveHour: 5], ageMinutes: 60 * 48),
            ],
            activeInstance: "Primary", now: now)

        XCTAssertNil(advice.recommended)
    }

    func testActiveAccountIsNeverRecommendedToItself() {
        let advice = Steering.advise(
            accounts: [account("Only", [.fiveHour: 99])],
            activeInstance: "Only", now: now)

        XCTAssertNil(advice.recommended)
        XCTAssertEqual(advice.urgency, .approaching)
    }

    func testUnknownActiveInstanceStillReportsTheBestOption() {
        // Nothing focused yet — no warning to give, but the ranking is still useful.
        let advice = Steering.advise(
            accounts: [
                account("Primary", [.fiveHour: 90]),
                account("Second", [.fiveHour: 5]),
            ],
            activeInstance: nil, now: now)

        XCTAssertEqual(advice.urgency, .none)
        XCTAssertEqual(advice.recommended, "Second")
    }

    // MARK: - Thresholds are configurable

    func testThresholdsCanBeTightened() {
        var t = Steering.Thresholds()
        t.approaching = 50

        let advice = Steering.advise(
            accounts: [account("Primary", [.fiveHour: 60]), account("Second", [.fiveHour: 5])],
            activeInstance: "Primary", now: now, thresholds: t)

        XCTAssertEqual(advice.urgency, .approaching)
    }
}
