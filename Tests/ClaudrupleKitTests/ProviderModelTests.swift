import XCTest
@testable import ClaudrupleKit

/// The normalised shape every provider reports into.
///
/// Seventeen services measure completely different things — percentages, dollars, credits,
/// seats, events. One view and one alerting engine can only serve all of them if they land
/// in a common shape, and the shape has to keep enough context that "80" from one provider
/// and "80" from another are not silently treated as comparable.
final class ProviderModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Utilisation is derived, never assumed

    func testUtilisationIsComputedFromValueAndLimit() {
        let m = ProviderMetric(
            key: "credits", label: "Credits", kind: .count,
            value: 250, limit: 1000, unit: "credits")
        XCTAssertEqual(m.utilization, 25)
    }

    func testUtilisationIsNilWithoutALimit() {
        // Spend with no cap has no percentage. Inventing one — against a monthly budget the
        // user never set — would put a fabricated number in front of an alert threshold.
        let m = ProviderMetric(
            key: "spend", label: "Spend", kind: .currency, value: 42.5, limit: nil, unit: "USD")
        XCTAssertNil(m.utilization)
    }

    func testAlreadyPercentageMetricsReportThemselves() {
        let m = ProviderMetric(
            key: "five_hour", label: "5-hour", kind: .percentOfLimit,
            value: 61, limit: 100, unit: nil)
        XCTAssertEqual(m.utilization, 61)
    }

    func testZeroLimitDoesNotProduceInfinity() {
        let m = ProviderMetric(
            key: "x", label: "X", kind: .count, value: 5, limit: 0, unit: nil)
        XCTAssertNil(m.utilization, "a zero limit is missing data, not a full bucket")
    }

    // MARK: - Formatting carries the unit

    func testCurrencyFormatsWithItsUnit() {
        let m = ProviderMetric(
            key: "spend", label: "Spend", kind: .currency, value: 42.5, limit: nil, unit: "USD")
        XCTAssertEqual(m.formattedValue, "42.50 USD")
    }

    func testCountsFormatWithoutDecimals() {
        let m = ProviderMetric(
            key: "events", label: "Events", kind: .count,
            value: 1_250_000, limit: nil, unit: "events")
        XCTAssertEqual(m.formattedValue, "1,250,000 events")
    }

    func testPercentagesFormatAsPercentages() {
        let m = ProviderMetric(
            key: "q", label: "Q", kind: .percentOfLimit, value: 61.5, limit: 100, unit: nil)
        XCTAssertEqual(m.formattedValue, "61.5%")
    }

    // MARK: - Snapshots

    func testSnapshotSurfacesItsMostConstrainedMetric() {
        let snap = ProviderSnapshot(
            providerID: "demo", accountLabel: "acme", capturedAt: now,
            metrics: [
                ProviderMetric(key: "a", label: "A", kind: .count, value: 10, limit: 100, unit: nil),
                ProviderMetric(key: "b", label: "B", kind: .count, value: 90, limit: 100, unit: nil),
            ])
        XCTAssertEqual(snap.binding?.key, "b")
    }

    func testUnboundedMetricsCannotBind() {
        // A large uncapped spend must not outrank a nearly-full quota just because its
        // raw number is bigger.
        let snap = ProviderSnapshot(
            providerID: "demo", accountLabel: nil, capturedAt: now,
            metrics: [
                ProviderMetric(
                    key: "spend", label: "Spend", kind: .currency,
                    value: 9999, limit: nil, unit: "USD"),
                ProviderMetric(key: "q", label: "Q", kind: .count, value: 95, limit: 100, unit: nil),
            ])
        XCTAssertEqual(snap.binding?.key, "q")
    }

    func testSnapshotWithNoBoundedMetricsHasNoBinding() {
        let snap = ProviderSnapshot(
            providerID: "demo", accountLabel: nil, capturedAt: now,
            metrics: [
                ProviderMetric(
                    key: "spend", label: "Spend", kind: .currency,
                    value: 10, limit: nil, unit: "USD")
            ])
        XCTAssertNil(snap.binding)
    }

    // MARK: - Credential specs are documentation the code can check

    func testCredentialSpecStatesTheMinimumScope() {
        // Every adapter must say what the least-privileged token looks like, so the docs
        // and `doctor` read from the same source instead of drifting apart.
        let spec = CredentialSpec(
            keychainService: "claudruple.demo",
            createURL: "https://example.com/tokens",
            minimumScope: "billing:read",
            scopeWarning: "A full-access token could spend money.")

        XCTAssertEqual(spec.minimumScope, "billing:read")
        XCTAssertFalse(spec.createURL.isEmpty)
    }
}
