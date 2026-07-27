import Foundation

/// A Claude instance as found on disk.
public struct DiscoveredInstance: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let appURL: URL
    public let profileURL: URL
    /// True for `/Applications/Claude.app`, which Claudruple never modifies.
    public let isPrimary: Bool
}

/// Finds Claude instances and maps each to the profile directory it actually uses.
public enum InstanceLocator {

    public static let claudeBundlePrefix = "com.anthropic.claudefordesktop"
    public static let primaryBundleID = claudeBundlePrefix
    public static let primaryAppPath = "/Applications/Claude.app"
    public static let instancesDirectory = "/Applications/Claudruple"

    /// Helper bundles share the prefix (`…claudefordesktop.helper`) but are nested inside
    /// a parent app. Clones are distinguished by the `.claudruple.` infix that
    /// create-instance.sh assigns.
    public static func isClaudeInstance(bundleID: String) -> Bool {
        if bundleID == primaryBundleID { return true }
        return bundleID.hasPrefix("\(claudeBundlePrefix).claudruple.")
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
        return support
            .appendingPathComponent("Claudruple")
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
        let entries = (try? FileManager.default.contentsOfDirectory(
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
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return DiscoveredInstance(
            name: name,
            bundleID: bundleID,
            appURL: appURL,
            profileURL: profileURL(bundleID: bundleID, displayName: name, home: home),
            isPrimary: bundleID == primaryBundleID)
    }
}
