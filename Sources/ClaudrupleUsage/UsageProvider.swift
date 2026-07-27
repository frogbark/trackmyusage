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

    public init(required: Bool, readOnlyScope: String, instructions: String) {
        self.required = required
        self.readOnlyScope = readOnlyScope
        self.instructions = instructions
    }
}

/// Somewhere secrets live that is not the repository or a dotfile.
public protocol CredentialStore: Sendable {
    func secret(for provider: String) throws -> String?
    func set(_ secret: String?, for provider: String) throws
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
    func fetch(secret: String?, now: Date) async throws -> [Metric]
}

extension UsageProvider {

    /// Never throws.
    ///
    /// A provider being down, rate-limited, or unconfigured is the normal state of at least
    /// one of seventeen at any moment. Propagating that would let a single timeout take out
    /// the whole render, and the wallpaper's own design already has a place to show it.
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
            let metrics = try await fetch(secret: secret, now: now)
            return UsageSnapshot(
                provider: id, account: nil, observedAt: now, status: .ok, metrics: metrics)
        } catch {
            return failed(.unavailable(describe(error)), now)
        }
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
