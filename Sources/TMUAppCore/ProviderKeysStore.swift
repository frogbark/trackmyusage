import Foundation
import TMUProviders

/// What the providers screen knows about one integration.
///
/// Note what is absent: the secret. This carries whether one is stored, never its value.
/// A view model holding live API keys would put every one of them into whatever a crash
/// report, a memory dump or a SwiftUI diagnostic captures — for a screen whose only
/// question is which providers are connected.
public struct ProviderKeyRow: Identifiable, Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// An adapter exists and this build can fetch from it.
        case built
        /// Intended, no adapter yet.
        case planned
        /// The vendor exposes nothing to read. Carries the reason so the screen can say it.
        case blocked(String)
    }

    /// Whether this provider takes a key at all, and whether it insists.
    ///
    /// Three states, not two. The first version of this asked only whether a credential was
    /// *required*, which silently excluded GitHub: it answers `/rate_limit` unauthenticated
    /// at a lower ceiling, so it is `required: false` — and so the screen never offered it a
    /// field, and a token already in the keychain read as not connected. A provider that
    /// works better with a key but survives without one is the interesting case, not an edge
    /// case to fold into "not needed".
    public enum CredentialNeed: Sendable, Equatable {
        /// Read locally, or no adapter to give a key to.
        case none
        /// Works without one; a key unlocks more than the anonymous ceiling allows.
        case optional
        case required
    }

    public let id: String
    public let availability: Availability
    public let credential: CredentialNeed
    public let isConnected: Bool
    /// The narrowest scope that still answers the question.
    public let readOnlyScope: String?
    public let instructions: String?
    public let createURL: String?
    public let scopeWarning: String?

    /// True when there is a token to paste and nothing pasted yet.
    public var isActionable: Bool {
        if case .built = availability { return credential != .none && !isConnected }
        return false
    }

    /// Which section of the screen this belongs in.
    ///
    /// One definition rather than a filter per section. The screen first grouped by three
    /// ad-hoc predicates whose last one was a catch-all — and Claude, which is built, needs
    /// no key and is the single thing this product exists to track, fell through it into a
    /// section headed "Not available yet". Every row it did not otherwise describe was
    /// quietly relabelled as unavailable.
    public enum Group: Sendable, Equatable {
        /// Reporting right now — either connected, or reading local files and never needing
        /// a key at all.
        case reporting
        /// An adapter exists and is waiting for a key.
        case connectable
        /// No adapter, or the vendor exposes nothing to read.
        case unavailable
    }

    public var group: Group {
        if isConnected { return .reporting }
        if isActionable { return .connectable }
        if case .built = availability, credential == .none { return .reporting }
        return .unavailable
    }
}

/// The providers screen's state.
///
/// Reads presence from the keychain and writes secrets straight through to it. Nothing is
/// cached, kept or copied: `connect` hands the string to `CredentialStore` and returns, and
/// the only thing that survives the call is a Bool saying an item now exists.
@MainActor
public final class ProviderKeysStore: ObservableObject {

    @Published public private(set) var rows: [ProviderKeyRow] = []
    /// Set when the keychain refuses. Surfaced rather than swallowed — a token that looks
    /// saved and is not produces a provider that silently never reports.
    @Published public private(set) var lastError: String?

    private let credentials: any CredentialStore

    public init(credentials: any CredentialStore = KeychainCredentials()) {
        self.credentials = credentials
        reload()
    }

    /// Rebuild the list from the registry and the keychain.
    public func reload() {
        let adapters = ProviderRegistry.all()
        let byID = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        let built = Set(ProviderRegistry.built)

        rows = ProviderRegistry.intended.map { id in
            let spec = byID[id]?.credentialSpec
            // No adapter means nothing to give a key to. `claude` is built and lands here
            // deliberately: its usage comes from local files, and a token would invent a
            // barrier that does not exist.
            let credential: ProviderKeyRow.CredentialNeed =
                switch spec {
                case .none: .none
                case .some(let spec): spec.required ? .required : .optional
                }

            let availability: ProviderKeyRow.Availability
            if let reason = ProviderRegistry.blocked[id] {
                availability = .blocked(reason)
            } else if built.contains(id) {
                availability = .built
            } else {
                availability = .planned
            }

            return ProviderKeyRow(
                id: id,
                availability: availability,
                credential: credential,
                isConnected: credential != .none && credentials.has(id),
                readOnlyScope: spec?.readOnlyScope,
                instructions: spec?.instructions,
                createURL: spec?.createURL,
                scopeWarning: spec?.scopeWarning)
        }
    }

    /// Store a token for a provider.
    ///
    /// Trimmed, because a token pasted from a web page arrives with whitespace far more
    /// often than not, and a trailing newline in an Authorization header fails as a 401 that
    /// looks exactly like a wrong key.
    ///
    /// The caller is expected to clear its own field afterwards; `secret` is not retained
    /// here beyond the call.
    @discardableResult
    public func connect(_ secret: String, to provider: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "That looks empty — nothing was saved."
            return false
        }
        do {
            try credentials.set(trimmed, for: provider)
            lastError = nil
            reload()
            return true
        } catch {
            // The error's description, never the secret. `CredentialError` carries an OSStatus
            // and nothing else, which is the reason it is safe to show at all.
            lastError = "Could not save to the keychain: \(error)"
            return false
        }
    }

    /// Remove a provider's token.
    @discardableResult
    public func disconnect(_ provider: String) -> Bool {
        do {
            try credentials.set(nil, for: provider)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = "Could not remove from the keychain: \(error)"
            return false
        }
    }

    public func dismissError() { lastError = nil }
}
