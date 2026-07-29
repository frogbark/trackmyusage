import Foundation

/// A Claude instance as found on disk.
public struct DiscoveredInstance: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let appURL: URL
    public let profileURL: URL
    /// True for `/Applications/Claude.app`, which TrackMyUsage never modifies.
    public let isPrimary: Bool
    /// `CFBundleShortVersionString`, or nil when the bundle would not say.
    ///
    /// Optional rather than defaulted to a placeholder: a clone whose version cannot be
    /// read is a different situation from one that matches, and `InstanceFreshness` keeps
    /// them apart rather than reporting the unreadable one as fine.
    public let version: String?

    public init(
        name: String, bundleID: String, appURL: URL, profileURL: URL, isPrimary: Bool,
        version: String? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.appURL = appURL
        self.profileURL = profileURL
        self.isPrimary = isPrimary
        self.version = version
    }
}

/// Finds Claude instances and maps each to the profile directory it actually uses.
public enum InstanceLocator {

    public static let claudeBundlePrefix = "com.anthropic.claudefordesktop"
    public static let primaryBundleID = claudeBundlePrefix
    public static let primaryAppPath = "/Applications/Claude.app"
    public static let instancesDirectory = LegacyNames.instancesDirectory

    /// Helper bundles share the prefix (`…claudefordesktop.helper`) but are nested inside
    /// a parent app. Clones are distinguished by the infix create-instance.sh assigns —
    /// which predates the rename and cannot change. See `LegacyNames`.
    public static func isClaudeInstance(bundleID: String) -> Bool {
        if bundleID == primaryBundleID { return true }
        return bundleID.hasPrefix("\(claudeBundlePrefix).\(LegacyNames.instanceBundleInfix).")
    }

    /// Where an instance keeps its Electron profile.
    ///
    /// This must stay in lockstep with create-instance.sh, which compiles the launcher
    /// shim with `USER_DATA_DIR="$HOME/Library/Application Support/Claudruple/$NAME"`.
    /// If the two ever disagree, the CLI would silently inspect a directory the app does
    /// not use — and report a converged instance that is nothing of the sort.
    public static func profileURL(bundleID: String, displayName: String, home: URL) -> URL {
        let support = home.appendingPathComponent("Library/Application Support")
        guard bundleID != primaryBundleID else {
            return support.appendingPathComponent("Claude")
        }
        return
            support
            .appendingPathComponent(LegacyNames.instanceProfileDirectory)
            .appendingPathComponent(displayName)
    }

    /// Every instance installed on this machine.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        primaryPath: String = primaryAppPath,
        instancesPath: String = instancesDirectory
    ) -> [DiscoveredInstance] {
        var found: [DiscoveredInstance] = []

        if let primary = describe(URL(fileURLWithPath: primaryPath), home: home) {
            found.append(primary)
        }

        let dir = URL(fileURLWithPath: instancesPath)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []

        for app in entries.sorted(by: { $0.path < $1.path }) where app.pathExtension == "app" {
            if let inst = describe(app, home: home) { found.append(inst) }
        }
        return found
    }

    private static func describe(_ appURL: URL, home: URL) -> DiscoveredInstance? {
        guard let bundle = Bundle(url: appURL),
            let bundleID = bundle.bundleIdentifier,
            isClaudeInstance(bundleID: bundleID)
        else { return nil }

        // CFBundleName is pinned to "Claude" on every clone so Electron can find its
        // helpers, so the display name is the only thing that distinguishes them.
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return DiscoveredInstance(
            name: name,
            bundleID: bundleID,
            appURL: appURL,
            profileURL: profileURL(bundleID: bundleID, displayName: name, home: home),
            isPrimary: bundleID == primaryBundleID,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String)
    }
}

extension Collection where Element == DiscoveredInstance {

    /// The version of `/Applications/Claude.app`, which every clone is measured against.
    ///
    /// The primary is the reference rather than a participant: it is the thing being cloned
    /// from, and TrackMyUsage never modifies it.
    public var installedClaudeVersion: String? {
        first(where: \.isPrimary)?.version
    }

    /// Each clone paired with how it compares to the installed Claude.
    ///
    /// The primary is excluded because "is Claude the same version as Claude" is not a
    /// question, and including it would put a permanent `up to date` row in every listing
    /// that says nothing.
    public func freshness() -> [(instance: DiscoveredInstance, freshness: InstanceFreshness)] {
        let installed = installedClaudeVersion
        return
            filter { !$0.isPrimary }
            .map {
                ($0, InstanceFreshness.compare(clone: $0.version, installed: installed))
            }
    }

    /// Clones that are on a different build from the installed Claude.
    public var needingRefresh: [DiscoveredInstance] {
        freshness().filter(\.freshness.needsRefresh).map(\.instance)
    }
}
