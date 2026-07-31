import Foundation

/// What a provider needs before it can be asked anything.
public struct CredentialSpec: Sendable, Equatable {
    /// False for providers whose data is already local. Claude is the case — requiring a
    /// token there would invent a barrier that does not exist.
    public let required: Bool
    /// The narrowest scope that still answers the question.
    ///
    /// Declared here rather than written in documentation so it travels with the adapter
    /// and can be shown at the moment someone is pasting a token in. A leaked credential
    /// should not be able to spend money or change infrastructure.
    public let readOnlyScope: String
    /// Where to click to get one.
    public let instructions: String
    /// The page that mints the token, so the setup flow can open it directly instead of
    /// making someone hunt for it.
    public let createURL: String?
    /// What a broader token would allow. Stated plainly, because the trade-off is only a
    /// real choice if the cost of the easy option is visible at the moment of choosing.
    public let scopeWarning: String?

    public init(
        required: Bool, readOnlyScope: String, instructions: String,
        createURL: String? = nil, scopeWarning: String? = nil
    ) {
        self.required = required
        self.readOnlyScope = readOnlyScope
        self.instructions = instructions
        self.createURL = createURL
        self.scopeWarning = scopeWarning
    }
}

/// What an adapter returns: readings, plus which account they came from.
///
/// The account travels with the readings rather than being stamped afterwards, because
/// only the adapter can know it — Stripe reports live vs test, ElevenLabs reports the plan
/// tier, and both are parsed out of the same response as the numbers.
public struct ProviderReading: Sendable, Equatable {
    public let account: String?
    public let metrics: [Metric]

    public init(account: String? = nil, metrics: [Metric]) {
        self.account = account
        self.metrics = metrics
    }
}

/// Somewhere secrets live that is not the repository or a dotfile.
public protocol CredentialStore: Sendable {
    func secret(for provider: String) throws -> String?
    func set(_ secret: String?, for provider: String) throws
    /// Whether a secret is stored, without reading it.
    ///
    /// Its own operation because the answer a settings screen needs is "is this connected",
    /// and satisfying that by fetching the token copies a live credential into the address
    /// space of a process that has no use for it — once per provider, every time the list
    /// redraws. The keychain can answer presence without returning the bytes, so it should.
    func has(_ provider: String) -> Bool
}

extension CredentialStore {
    /// Falls back to a read for stores that cannot answer presence any other way.
    ///
    /// Correct for the in-memory store the tests use, where there is no secret to protect.
    /// `KeychainCredentials` overrides it.
    public func has(_ provider: String) -> Bool {
        ((try? secret(for: provider)) ?? nil) != nil
    }
}

/// One integration.
///
/// Adapters implement `fetch` and nothing else. Turning a failure into a snapshot, checking
/// for a missing credential, and stamping the identity are done once here, so seventeen
/// adapters cannot disagree about what an outage looks like.
public protocol UsageProvider: Sendable {
    var id: String { get }
    var credentialSpec: CredentialSpec { get }

    /// Returns the current readings. Throwing is expected rather than exceptional.
    func fetch(secret: String?, now: Date) async throws -> ProviderReading
}

extension UsageProvider {

    /// Never throws.
    ///
    /// A provider being down, rate-limited, or unconfigured is the normal state of at least
    /// one of seventeen at any moment. Propagating that would let a single timeout take out
    /// the whole render, and every surface already has a place to show it.
    public func snapshot(credentials: CredentialStore, now: Date) async -> UsageSnapshot {
        let secret: String?
        do {
            secret = try credentials.secret(for: id)
        } catch {
            return failed(.unavailable("could not read the stored credential: \(error)"), now)
        }

        if credentialSpec.required && (secret?.isEmpty ?? true) {
            return failed(.unauthorized, now)
        }

        do {
            let reading = try await fetch(secret: secret, now: now)
            return UsageSnapshot(
                provider: id, account: reading.account, observedAt: now,
                status: .ok, metrics: reading.metrics)
        } catch {
            return failed(classify(error), now)
        }
    }

    /// A rejected credential is not an outage.
    ///
    /// 401 and 403 both mean the token has to be replaced — one is invalid, the other
    /// lacks the scope, and either way waiting will not help. Reporting them as
    /// `unavailable` alongside a 500 sends someone to wait out a token that will never
    /// start working. Everything else genuinely is worth retrying.
    private func classify(_ error: Error) -> UsageSnapshot.Status {
        if case HTTPError.status(let code) = error, code == 401 || code == 403 {
            return .unauthorized
        }
        return .unavailable(describe(error))
    }

    /// A failed provider still occupies its row. Dropping it would make an outage look
    /// identical to never having configured the thing at all.
    private func failed(_ status: UsageSnapshot.Status, _ now: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: id, account: nil, observedAt: now, status: status, metrics: [])
    }

    private func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        return "\(error)"
    }
}
