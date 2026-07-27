import Foundation
import Security

/// Where provider API keys live.
///
/// Secrets never touch the manifest, the config, or the repo — the manifest is designed to
/// be committed and shared, so anything in it is effectively public.
public protocol CredentialStore {
    func get(_ service: String) throws -> String?
    mutating func set(_ value: String, for service: String) throws
    mutating func delete(_ service: String) throws
}

public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "keychain error \(status): \(msg)"
        }
    }
}

/// The real store.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    private func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    public func get(_ service: String) throws -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public mutating func set(_ value: String, for service: String) throws {
        let data = Data(value.utf8)

        // SecItemAdd returns errSecDuplicateItem when the service already exists, so a
        // plain add would make the second save silently do nothing. Update first, and
        // only insert when there is nothing to update.
        let updateStatus = SecItemUpdate(
            query(service) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.keychain(updateStatus)
        }

        var insert = query(service)
        insert[kSecValueData as String] = data
        // Available without unlocking on this device only; never synced to iCloud.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    }

    public mutating func delete(_ service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }
}

/// A real store that keeps nothing on disk. Used by tests and by dry runs.
public struct InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ service: String) throws -> String? { values[service] }
    public mutating func set(_ value: String, for service: String) throws {
        values[service] = value
    }
    public mutating func delete(_ service: String) throws { values[service] = nil }
}
