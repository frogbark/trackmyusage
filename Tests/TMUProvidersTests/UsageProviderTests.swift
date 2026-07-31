import Foundation
import XCTest

@testable import TMUProviders

final class UsageProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Credentials

    func testAProviderNeedingACredentialIsUnauthorizedWithoutOne() async {
        // The distinction that matters on screen: "you have not connected this" is not the
        // same as "this is broken", and neither is "you are using none of it".
        let store = InMemoryCredentials()
        let provider = StubProvider(id: "openai", requiresCredential: true)

        let snapshot = await provider.snapshot(credentials: store, now: now)

        XCTAssertEqual(snapshot.status, .unauthorized)
        XCTAssertFalse(snapshot.isReporting)
    }

    func testAProviderNeedingNoCredentialRunsWithoutOne() async {
        // Claude is the case: the data is already on disk, so requiring a credential would
        // be inventing a barrier that does not exist.
        let provider = StubProvider(id: "claude", requiresCredential: false)

        let snapshot = await provider.snapshot(credentials: InMemoryCredentials(), now: now)

        XCTAssertTrue(snapshot.isReporting)
    }

    func testAStoredCredentialIsPassedToTheProvider() async throws {
        let store = InMemoryCredentials()
        try store.set("sk-test", for: "openai")
        let provider = StubProvider(id: "openai", requiresCredential: true)

        let snapshot = await provider.snapshot(credentials: store, now: now)

        XCTAssertTrue(snapshot.isReporting)
        XCTAssertEqual(provider.seenSecret, "sk-test")
    }

    // MARK: - Failure

    func testAThrowingProviderBecomesAnUnavailableSnapshotRatherThanPropagating() async {
        // One provider's outage must not take down the render for the other sixteen, and a
        // timeout is the normal case rather than the exceptional one.
        let provider = StubProvider(id: "sentry", requiresCredential: false)
        provider.failure = URLError(.timedOut)

        let snapshot = await provider.snapshot(credentials: InMemoryCredentials(), now: now)

        XCTAssertFalse(snapshot.isReporting)
        guard case .unavailable(let reason) = snapshot.status else {
            return XCTFail("expected unavailable, got \(snapshot.status)")
        }
        XCTAssertFalse(reason.isEmpty, "the reason reaches the UI, so it cannot be blank")
    }

    func testTheSnapshotCarriesTheProviderIdentityEvenWhenItFails() async {
        // A failed snapshot still has to occupy its row, or the provider silently vanishes
        // from the widget and looks like it was never configured.
        let provider = StubProvider(id: "resend", requiresCredential: true)

        let snapshot = await provider.snapshot(credentials: InMemoryCredentials(), now: now)

        XCTAssertEqual(snapshot.provider, "resend")
        XCTAssertEqual(snapshot.observedAt, now)
    }

    // MARK: - Scopes

    func testEveryProviderDeclaresAMinimumReadOnlyScope() {
        // A leaked token must not be able to spend money or mutate infrastructure, so the
        // scope is part of the provider's declaration rather than documentation.
        let spec = StubProvider(id: "vercel", requiresCredential: true).credentialSpec

        XCTAssertFalse(spec.readOnlyScope.isEmpty)
        XCTAssertFalse(spec.instructions.isEmpty, "the UI has to tell people where to click")
    }
}

// MARK: - Doubles

private final class StubProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let credentialSpec: CredentialSpec
    var failure: Error?
    private(set) var seenSecret: String?

    init(id: String, requiresCredential: Bool) {
        self.id = id
        self.credentialSpec = CredentialSpec(
            required: requiresCredential,
            readOnlyScope: "read:usage",
            instructions: "Settings → Tokens → create a read-only token")
    }

    func fetch(secret: String?, now: Date) async throws -> ProviderReading {
        if let failure { throw failure }
        seenSecret = secret
        return ProviderReading(metrics: [
            Metric(
                key: "usage", kind: .percentOfLimit, value: 42, limit: nil,
                window: .rolling(3600), resetsAt: nil)
        ])
    }
}

private final class InMemoryCredentials: CredentialStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]

    func secret(for provider: String) throws -> String? { secrets[provider] }
    func set(_ secret: String?, for provider: String) throws {
        secrets[provider] = secret
    }
}
