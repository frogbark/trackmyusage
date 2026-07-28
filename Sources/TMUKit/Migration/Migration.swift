import Foundation

#if canImport(Security)
import Security
#endif

/// The one call every entry point makes.
///
/// `tmu`, `tmud` and the app all reach this, because any of them can be the first thing a
/// user runs after upgrading and none can assume another went first. The daemon in
/// particular fires every five minutes under launchd, so "runs at most once" has to be true
/// across processes, not merely within one.
public enum Migration {

    /// Migrate if needed. Returns the receipt when work was attempted, `nil` when there was
    /// nothing to do or another process holds the lock.
    ///
    /// Never throws. A failure here must not stop the program the user actually asked for.
    @discardableResult
    public static func runOnceIfNeeded(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        legacyKeychainService: String,
        newKeychainService: String
    ) -> MigrationReceipt? {
        let receiptURL = receiptURL(home: home)

        // Fast path: one stat. This runs on every single invocation of every binary, so it
        // has to cost approximately nothing once migration is behind us.
        if let existing = loadReceipt(receiptURL), existing.isComplete { return nil }

        let files = SystemFileMover()
        let environment = MigrationEnvironment(
            home: home,
            exists: { files.exists($0) },
            hasLegacyKeychainItems: { KeychainRelabeler.hasItems(service: legacyKeychainService) })

        let plan = MigrationPlan.probe(environment)
        guard !plan.isEmpty else {
            // Nothing to migrate. Record that, so a fresh install pays the probe once.
            try? writeReceipt(MigrationReceipt(outcomes: [:]), to: receiptURL, files: files)
            return nil
        }

        guard let lock = Lock(at: lockURL(home: home)) else { return nil }
        defer { lock.release() }

        // Re-check under the lock: another process may have finished between the fast path
        // and here, and running the plan twice would move an already-moved directory.
        if let existing = loadReceipt(receiptURL), existing.isComplete { return nil }

        let receipt = MigrationRunner(
            home: home,
            files: files,
            keychain: KeychainRelabeler(),
            launchctl: SystemLaunchctl(),
            legacyKeychainService: legacyKeychainService,
            newKeychainService: newKeychainService
        ).run(MigrationPlan.probe(environment))

        try? writeReceipt(receipt, to: receiptURL, files: files)
        return receipt
    }

    public static func receiptURL(home: URL) -> URL {
        LegacyPaths.supportDirectory(home: home)
            .appendingPathComponent("migration-receipt.json")
    }

    static func lockURL(home: URL) -> URL {
        LegacyPaths.supportDirectory(home: home).appendingPathComponent("migration.lock")
    }

    static func loadReceipt(_ url: URL) -> MigrationReceipt? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A receipt we cannot read is treated as no receipt: every step re-checks its own
        // precondition, so re-probing is safe and silently skipping is not.
        return try? JSONDecoder().decode(MigrationReceipt.self, from: data)
    }

    static func writeReceipt(_ receipt: MigrationReceipt, to url: URL, files: any FileMoving)
        throws
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(encoder.encode(receipt), to: url)
    }
}

/// An exclusive lock that cannot outlive a crash.
///
/// `O_EXCL` makes creation atomic across processes. The pid is written so a stale lock can
/// be identified by hand, and a lock older than an hour is broken automatically — a
/// migration that takes an hour has failed, and refusing to ever migrate again is worse
/// than racing.
private struct Lock {
    private let url: URL

    init?(at url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let created = attributes[.creationDate] as? Date,
            Date().timeIntervalSince(created) > 3600
        {
            try? FileManager.default.removeItem(at: url)
        }

        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return nil }
        _ = "\(ProcessInfo.processInfo.processIdentifier)".withCString {
            write(descriptor, $0, strlen($0))
        }
        close(descriptor)
    }

    func release() { try? FileManager.default.removeItem(at: url) }
}

#if canImport(Security)

/// Moves keychain items between services without ever reading their contents.
public struct KeychainRelabeler: KeychainRelabeling {
    public init() {}

    public static func hasItems(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func relabel(from oldService: String, to newService: String) throws -> Int {
        var relabelled = 0
        // One at a time rather than a bulk update: an item whose account already exists
        // under the new service must be left alone rather than collide, and SecItemUpdate
        // on a matched set gives no way to skip one.
        while true {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldService,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return relabelled }
            guard status == errSecSuccess,
                let attributes = item as? [String: Any],
                let account = attributes[kSecAttrAccount as String] as? String
            else { throw MigrationError.keychain(Int(status)) }

            let one: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldService,
                kSecAttrAccount as String: account,
            ]
            // No kSecValueData anywhere in this call: the secret is never decrypted,
            // never enters this process, and never leaves the keychain.
            let update = [kSecAttrService as String: newService]
            let updated = SecItemUpdate(one as CFDictionary, update as CFDictionary)

            if updated == errSecDuplicateItem {
                // Already present under the new service. Leave the old one; deleting it
                // would destroy the only copy if the two ever differed.
                return relabelled
            }
            guard updated == errSecSuccess else {
                throw MigrationError.keychain(Int(updated))
            }
            relabelled += 1
        }
    }
}

#endif
