import XCTest

@testable import TMUWidgets

final class SharedContainerTests: XCTestCase {

    /// A build with no App Group must degrade to nil rather than trapping. `IDENTITY=-`
    /// cannot carry the entitlement, so this is the ordinary ad-hoc build, not a fault — and
    /// a force-unwrap here would crash the app for every contributor without a signing
    /// identity.
    func testABundleWithNoGroupIdentifierYieldsNoContainerRatherThanCrashing() {
        let bundle = Bundle(for: type(of: self))
        XCTAssertNil(SharedContainer.groupIdentifier(bundle: bundle))
        XCTAssertNil(SharedContainer.url(bundle: bundle))
        XCTAssertNil(SharedContainer.modelURL(bundle: bundle))
    }

    /// An empty string is what a plist substitution produces when the Team ID could not be
    /// derived. Treating it as a present-but-blank identifier would ask the system for a
    /// container named "", which fails far from here.
    func testAnEmptyGroupIdentifierIsTreatedAsAbsent() {
        XCTAssertNil(SharedContainer.groupIdentifier(bundle: StubBundle(value: "")))
    }

    func testAGroupIdentifierIsReadFromTheInfoDictionary() {
        let stub = StubBundle(value: "TEAMID.com.trackmyusage.shared")
        XCTAssertEqual(
            SharedContainer.groupIdentifier(bundle: stub), "TEAMID.com.trackmyusage.shared")
    }
}

/// Bundle's Info dictionary is read-only, so the seam is subclassing the one accessor used.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let value: String
    init(value: String) {
        self.value = value
        super.init()
    }
    override func object(forInfoDictionaryKey key: String) -> Any? {
        key == SharedContainer.infoKey ? value : nil
    }
}
