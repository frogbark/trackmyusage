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

    private let service: String

    public init(service: String = "com.claudruple.usage") {
        self.service = service
    }

    public func secret(for provider: String) throws -> String? {
        var query = baseQuery(provider)
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

    public func set(_ secret: String?, for provider: String) throws {
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(baseQuery(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(Int(status))
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

    private func baseQuery(_ provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
