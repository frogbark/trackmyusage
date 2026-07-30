#if canImport(Security)

import Foundation
import Security

/// Secrets in the login keychain, never on disk and never in the repository.
///
/// One generic-password item per provider, keyed by service name. Items are marked
/// `AfterFirstUnlock` rather than `WhenUnlocked` so the sampler can keep running on a
/// machine that has booted but not been logged into interactively — which is the normal
/// state for something driven by a launch agent.
public struct KeychainCredentials: CredentialStore {

    /// Where secrets are written.
    public static let defaultService = "com.trackmyusage.usage"

    /// Where secrets were written before the rename, and where reads still fall back to.
    ///
    /// This is the one frozen name that cannot live in `TMUKit.LegacyNames` with the other
    /// three: this target deliberately depends on nothing so it builds where Claude Desktop
    /// does not exist, and importing TMUKit to reach a string constant would trade that away.
    ///
    /// The fallback is permanent rather than transitional. Migration relabels items in place,
    /// but a keychain that was locked at the moment migration ran — or an item the user
    /// declined to unlock — is left behind, and re-adding a token by hand is a worse outcome
    /// than one extra lookup that returns nothing.
    public static let legacyService = "com.claudruple.usage"

    private let service: String
    private let fallbackService: String?

    public init(service: String = KeychainCredentials.defaultService) {
        self.service = service
        // Only fall back when reading the current service. A caller that names a service
        // explicitly is asking about that service, and should not silently get another.
        self.fallbackService = service == Self.defaultService ? Self.legacyService : nil
    }

    public func secret(for provider: String) throws -> String? {
        if let found = try secret(for: provider, in: service) { return found }
        guard let fallbackService else { return nil }
        return try secret(for: provider, in: fallbackService)
    }

    private func secret(for provider: String, in service: String) throws -> String? {
        var query = baseQuery(provider, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            // Not an error. A provider nobody has connected yet is the common case, and
            // the caller turns it into `unauthorized` rather than a failure.
            return nil
        default:
            throw CredentialError.keychain(Int(status))
        }
    }

    /// Presence, without returning the secret.
    ///
    /// `kSecReturnData` is deliberately absent: the query asks the keychain whether an item
    /// exists and nothing more, so the token is never copied into this process to answer a
    /// question that is not about its value. The settings screen redraws on every keystroke
    /// elsewhere in the window, and each redraw would otherwise have been a fetch.
    ///
    /// Checks the legacy service too, on the same reasoning as `secret(for:)` — an item left
    /// behind by an interrupted migration is still a connected provider, and reporting it as
    /// unconnected would invite someone to paste a token they already have.
    public func has(_ provider: String) -> Bool {
        for service in [service] + (fallbackService.map { [$0] } ?? []) {
            var query = baseQuery(provider, service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    public func set(_ secret: String?, for provider: String) throws {
        guard let secret, !secret.isEmpty else {
            // Delete from the legacy service too. Removing only the current one would
            // "remove" a token that the read fallback then resurrects on the next call —
            // a disconnected provider that keeps reporting.
            for service in [service] + (fallbackService.map { [$0] } ?? []) {
                let status = SecItemDelete(baseQuery(provider, service: service) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw CredentialError.keychain(Int(status))
                }
            }
            return
        }

        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var insert = baseQuery(provider)
            insert[kSecValueData as String] = data
            // AfterFirstUnlock so a launch agent can read it on a booted-but-not-logged-in
            // machine; ThisDeviceOnly because a provider API key has no business
            // replicating to iCloud Keychain and every other device on the account.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.keychain(Int(added)) }
            return
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(Int(status)) }
    }

    private func baseQuery(_ provider: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: provider,
        ]
    }
}

public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case keychain(Int)

    public var description: String {
        switch self {
        case .keychain(let status):
            return "keychain error \(status)"
        }
    }
}

#endif
