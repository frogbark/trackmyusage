import Foundation

/// Where a piece of Claude Desktop configuration is meaningful.
public enum ConfigScope: Sendable, Equatable {
    /// Tooling: extensions, skills, plugins. The reason sync exists.
    case environment
    /// Belongs to one account. Copying it across instances is a security failure.
    case account
    /// Local to this machine and install. Copying it is merely useless.
    case machine

    /// Only environment-scoped configuration may cross an instance boundary.
    public var isSyncable: Bool { self == .environment }

    /// Classify a configuration key or profile entry.
    ///
    /// Precedence is deliberate: account first, then machine, then environment as the
    /// default. Getting `.environment` wrong wastes a copy; getting `.account` wrong
    /// leaks a credential or a permission grant. When a key matches more than one rule,
    /// the more restrictive answer has to win.
    public static func of(_ key: String) -> ConfigScope {
        if isAccountScoped(key) { return .account }
        if isMachineScoped(key) { return .machine }
        return .environment
    }

    // MARK: - Account

    /// Named exactly. Everything else is matched structurally, so that keys Anthropic
    /// adds in a future release are classified correctly without a code change.
    private static let accountExact: Set<String> = [
        "lastKnownAccountUuid",
        "ant-device-registry.json",
        "ant-did",
    ]

    private static func isAccountScoped(_ key: String) -> Bool {
        // The suffix *is* the contract. Matching it rather than enumerating known names
        // means a new `somethingByAccount` setting is safe the day it ships; a denylist
        // of known names would silently start leaking on the next Claude release.
        if key.hasSuffix("ByAccount") { return true }

        // oauth:tokenCache, oauth:tokenCacheV2, and any future sibling.
        if key.hasPrefix("oauth:") { return true }

        if accountExact.contains(key) { return true }

        // Keys of the form `dxt:allowlistCache:<org-uuid>` are scoped to one
        // organisation. The bare key carries no UUID and is shared policy.
        if hasTrailingUUID(key) { return true }

        return false
    }

    /// True when the final colon-separated component is a UUID.
    private static func hasTrailingUUID(_ key: String) -> Bool {
        guard let last = key.split(separator: ":").last, key.contains(":") else { return false }
        return UUID(uuidString: String(last)) != nil
    }

    // MARK: - Machine

    /// Local state: regenerable, install-specific, or both. Excluded from sync because
    /// it is meaningless elsewhere — not because it is dangerous.
    private static let machineExact: Set<String> = [
        "Cookies", "Cookies-journal",
        "Local State", "Network Persistent State", "TransportSecurity",
        "DIPS", "Trust Tokens", "Crashpad", "blob_storage",
        "Service Worker", "Shared Dictionary", "VideoDecodeStats", "sentry",
        "window-state.json", "remoteToolsDeviceName",
    ]

    private static func isMachineScoped(_ key: String) -> Bool {
        if machineExact.contains(key) { return true }
        // Cache, Code Cache, GPUCache, DawnGraphiteCache, DawnWebGPUCache …
        if key.hasSuffix("Cache") { return true }
        // SQLite write-ahead logs and journals.
        if key.hasSuffix("-wal") || key.hasSuffix("-journal") { return true }
        return false
    }
}
