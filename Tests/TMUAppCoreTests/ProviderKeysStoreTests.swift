import TMUProviders
import XCTest

@testable import TMUAppCore

/// A credential store that records what it was asked to do.
///
/// Records rather than mocks: the point of most of these tests is not what came back but
/// what the store did — in particular whether it ever asked for a secret's *value* when it
/// only needed to know one existed.
private final class RecordingCredentials: CredentialStore, @unchecked Sendable {
    var stored: [String: String] = [:]
    var presenceChecks: [String] = []
    var valueReads: [String] = []
    var failOnWrite = false

    func secret(for provider: String) throws -> String? {
        valueReads.append(provider)
        return stored[provider]
    }

    func set(_ secret: String?, for provider: String) throws {
        if failOnWrite { throw CredentialError.keychain(-25299) }
        if let secret {
            stored[provider] = secret
        } else {
            stored.removeValue(forKey: provider)
        }
    }

    func has(_ provider: String) -> Bool {
        presenceChecks.append(provider)
        return stored[provider] != nil
    }
}

@MainActor
final class ProviderKeysStoreTests: XCTestCase {

    /// Prevents: the screen copying every API key on the machine into memory to draw a list
    /// of green dots — once per provider, on every reload.
    ///
    /// This is the reason `has` exists as its own operation. If someone later "simplifies"
    /// it back to a `secret(for:) != nil`, this fails.
    func testDrawingTheListNeverAsksForASecretsValue() {
        let credentials = RecordingCredentials()
        credentials.stored["github"] = "ghp_realtoken"

        let store = ProviderKeysStore(credentials: credentials)
        store.reload()

        XCTAssertFalse(credentials.presenceChecks.isEmpty, "presence was never checked")
        XCTAssertTrue(
            credentials.valueReads.isEmpty,
            "the list read secret values: \(credentials.valueReads)")
    }

    /// Prevents: a row model carrying the token it was asked about.
    ///
    /// The rows are `@Published` on an ObservableObject, so anything that captures view
    /// state — a crash report, a memory graph — captures whatever they hold.
    func testARowKnowsAProviderIsConnectedWithoutCarryingItsSecret() throws {
        let credentials = RecordingCredentials()
        credentials.stored["github"] = "ghp_realtoken"

        let store = ProviderKeysStore(credentials: credentials)
        let row = try XCTUnwrap(store.rows.first { $0.id == "github" })

        XCTAssertTrue(row.isConnected)
        let mirrored = Mirror(reflecting: row).children.compactMap { $0.value as? String }
        XCTAssertFalse(
            mirrored.contains("ghp_realtoken"), "the secret is stored on the row itself")
    }

    /// Prevents: a token pasted with the trailing newline every web page adds being stored
    /// verbatim, which fails later as a 401 indistinguishable from a wrong key.
    func testAPastedTokenIsTrimmedBeforeItIsStored() {
        let credentials = RecordingCredentials()
        let store = ProviderKeysStore(credentials: credentials)

        XCTAssertTrue(store.connect("  ghp_token\n", to: "github"))
        XCTAssertEqual(credentials.stored["github"], "ghp_token")
    }

    /// Prevents: whitespace being stored as a credential, which would make a provider look
    /// connected and report `unauthorized` forever.
    func testAnEmptyOrWhitespaceEntryIsRefusedRatherThanStored() {
        let credentials = RecordingCredentials()
        let store = ProviderKeysStore(credentials: credentials)

        XCTAssertFalse(store.connect("   \n ", to: "github"))
        XCTAssertNil(credentials.stored["github"])
        XCTAssertNotNil(store.lastError)
    }

    /// Prevents: a keychain failure being swallowed, leaving a screen that says connected
    /// about a provider that will never report.
    func testAFailedWriteIsSurfacedAndLeavesTheProviderUnconnected() throws {
        let credentials = RecordingCredentials()
        credentials.failOnWrite = true
        let store = ProviderKeysStore(credentials: credentials)

        XCTAssertFalse(store.connect("ghp_token", to: "github"))
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("keychain"))
        XCTAssertFalse(try XCTUnwrap(store.rows.first { $0.id == "github" }).isConnected)
    }

    /// Prevents: the error message carrying the secret it failed to store.
    ///
    /// The obvious way to write a failure message is to interpolate what was being saved.
    /// `lastError` is rendered on screen and would be copied into any bug report.
    func testAFailureMessageNeverContainsTheSecret() throws {
        let credentials = RecordingCredentials()
        credentials.failOnWrite = true
        let store = ProviderKeysStore(credentials: credentials)

        store.connect("sk_live_supersecret", to: "stripe")
        XCTAssertFalse(try XCTUnwrap(store.lastError).contains("sk_live_supersecret"))
    }

    /// Prevents: disconnect appearing to work while the credential survives.
    func testDisconnectingRemovesTheCredentialAndTheConnectedState() throws {
        let credentials = RecordingCredentials()
        credentials.stored["github"] = "ghp_token"
        let store = ProviderKeysStore(credentials: credentials)

        XCTAssertTrue(store.disconnect("github"))
        XCTAssertNil(credentials.stored["github"])
        XCTAssertFalse(try XCTUnwrap(store.rows.first { $0.id == "github" }).isConnected)
    }

    /// Prevents: offering a key field for a provider that reads local files.
    ///
    /// Claude needs no credential — asking for one would invent a barrier that does not
    /// exist, and there is no token that would make it work better.
    func testClaudeIsNeverOfferedAKeyField() throws {
        let store = ProviderKeysStore(credentials: RecordingCredentials())
        let claude = try XCTUnwrap(store.rows.first { $0.id == "claude" })

        XCTAssertEqual(claude.credential, .none)
        XCTAssertFalse(claude.isActionable)
        XCTAssertFalse(claude.isConnected)
    }

    /// Prevents: a provider with no adapter offering a field that would store a key which
    /// nothing reads — a token pasted into a void, and a user who believes they are covered.
    func testAProviderWithoutAnAdapterIsNotOfferedAKeyField() throws {
        let store = ProviderKeysStore(credentials: RecordingCredentials())

        for id in ProviderRegistry.pending {
            let row = try XCTUnwrap(store.rows.first { $0.id == id })
            XCTAssertFalse(row.isActionable, "\(id) offered a key field with no adapter")
        }
    }

    /// Prevents: a blocked provider losing the reason it is blocked.
    ///
    /// "Not written yet" is a promise; "the vendor exposes no endpoint" is a fact. Showing
    /// an unexplained grey row collapses the two.
    func testABlockedProviderKeepsItsReason() throws {
        let store = ProviderKeysStore(credentials: RecordingCredentials())
        let row = try XCTUnwrap(store.rows.first { $0.id == "higgsfield" })

        guard case .blocked(let reason) = row.availability else {
            return XCTFail("higgsfield should be blocked")
        }
        XCTAssertEqual(reason, ProviderRegistry.blocked["higgsfield"])
        XCTAssertFalse(row.isActionable)
    }

    /// Prevents: a provider that works unauthenticated being treated as taking no key.
    ///
    /// GitHub answers /rate_limit anonymously, so its spec says `required: false`. An
    /// earlier version of this screen read that as "no credential" and so never offered
    /// GitHub a field at all — while a token already in the keychain reported as
    /// unconnected. The provider people are most likely to already have a token for was
    /// the one provider they could not add.
    func testAProviderThatWorksUnauthenticatedStillTakesAKey() throws {
        let credentials = RecordingCredentials()
        let store = ProviderKeysStore(credentials: credentials)
        let github = try XCTUnwrap(store.rows.first { $0.id == "github" })

        XCTAssertEqual(github.credential, .optional)
        XCTAssertTrue(github.isActionable, "github was never offered a key field")

        XCTAssertTrue(store.connect("user:ghp_token", to: "github"))
        XCTAssertTrue(
            try XCTUnwrap(store.rows.first { $0.id == "github" }).isConnected,
            "a stored token did not read as connected")
    }

    /// Prevents: an adapter that demands a key being softened to optional.
    func testAProviderThatCannotWorkWithoutAKeySaysSo() throws {
        let store = ProviderKeysStore(credentials: RecordingCredentials())

        for id in ["stripe", "twilio", "elevenlabs"] {
            XCTAssertEqual(
                try XCTUnwrap(store.rows.first { $0.id == id }).credential, .required,
                "\(id) should require a key")
        }
    }

    /// Prevents: Claude being filed under "Not available yet".
    ///
    /// It is built, needs no key, and is the single thing this product exists to track. The
    /// screen's last section was once a catch-all predicate, so every row the earlier two
    /// did not describe landed there — Claude included, under a heading saying it was absent
    /// rather than stubbed. The tests at the time asserted Claude offered no key field, which
    /// was true and entirely beside the point, because none of them asked where it appeared.
    func testClaudeIsShownAsReportingRatherThanUnavailable() throws {
        let store = ProviderKeysStore(credentials: RecordingCredentials())
        let claude = try XCTUnwrap(store.rows.first { $0.id == "claude" })

        XCTAssertEqual(claude.group, .reporting)
    }

    /// Prevents: a row falling into a section that does not describe it.
    ///
    /// Every provider lands in exactly one group, and each group means what its heading
    /// says: reporting now, waiting for a key, or not available. A row can only be
    /// mis-filed if one of these is wrong.
    func testEveryRowIsGroupedByWhatIsActuallyTrueOfIt() throws {
        let credentials = RecordingCredentials()
        credentials.stored["stripe"] = "sk_live_token"
        let store = ProviderKeysStore(credentials: credentials)

        for row in store.rows {
            switch row.group {
            case .reporting:
                XCTAssertTrue(
                    row.isConnected || row.credential == .none,
                    "\(row.id) is in Reporting but has no key and is not local")
                XCTAssertEqual(row.availability, .built, "\(row.id) reports without an adapter")
            case .connectable:
                XCTAssertTrue(row.isActionable, "\(row.id) offers a field it cannot use")
                XCTAssertFalse(row.isConnected, "\(row.id) is connected and still offered")
            case .unavailable:
                XCTAssertNotEqual(
                    row.availability, .built,
                    "\(row.id) is built but shown as unavailable")
            }
        }

        XCTAssertEqual(
            try XCTUnwrap(store.rows.first { $0.id == "stripe" }).group, .reporting,
            "a connected provider should be reporting")
    }

    /// Prevents: the screen and the website disagreeing about what ships.
    ///
    /// Both derive from ProviderRegistry; this fails if the screen ever grows its own list.
    func testEveryIntendedProviderAppearsExactlyOnce() {
        let store = ProviderKeysStore(credentials: RecordingCredentials())

        XCTAssertEqual(store.rows.map(\.id), ProviderRegistry.intended)
        XCTAssertEqual(Set(store.rows.map(\.id)).count, store.rows.count)
    }
}
