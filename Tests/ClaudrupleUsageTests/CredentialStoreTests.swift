import XCTest
@testable import ClaudrupleUsage

final class CredentialStoreTests: XCTestCase {

    // MARK: - In-memory store
    //
    // Not a mock: it is a real conforming implementation used by tests and by --dry-run.
    // Its behaviour is the contract every store must satisfy.

    func testStoresAndRetrieves() throws {
        var store = InMemoryCredentialStore()
        try store.set("sk-123", for: "claudruple.demo")
        XCTAssertEqual(try store.get("claudruple.demo"), "sk-123")
    }

    func testMissingCredentialReadsAsNil() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.get("claudruple.absent"))
    }

    func testOverwritingReplaces() throws {
        var store = InMemoryCredentialStore()
        try store.set("old", for: "claudruple.demo")
        try store.set("new", for: "claudruple.demo")
        XCTAssertEqual(try store.get("claudruple.demo"), "new")
    }

    func testDeleteRemoves() throws {
        var store = InMemoryCredentialStore()
        try store.set("sk-123", for: "claudruple.demo")
        try store.delete("claudruple.demo")
        XCTAssertNil(try store.get("claudruple.demo"))
    }

    func testDeletingSomethingAbsentIsNotAnError() throws {
        var store = InMemoryCredentialStore()
        XCTAssertNoThrow(try store.delete("claudruple.absent"))
    }

    // MARK: - Keychain store
    //
    // Exercised against the real keychain with a throwaway service name, then cleaned up.
    // A stubbed keychain would only prove the stub works.

    func testKeychainRoundTrip() throws {
        var store = KeychainCredentialStore()
        let service = "claudruple.test.\(UUID().uuidString)"
        defer { try? store.delete(service) }

        try store.set("sk-roundtrip", for: service)
        XCTAssertEqual(try store.get(service), "sk-roundtrip")

        try store.delete(service)
        XCTAssertNil(try store.get(service))
    }

    func testKeychainOverwriteDoesNotDuplicate() throws {
        var store = KeychainCredentialStore()
        let service = "claudruple.test.\(UUID().uuidString)"
        defer { try? store.delete(service) }

        try store.set("first", for: service)
        try store.set("second", for: service)

        // SecItemAdd fails with errSecDuplicateItem on a second add, so overwrite has to
        // update rather than insert; otherwise the second save silently does nothing.
        XCTAssertEqual(try store.get(service), "second")
    }
}
