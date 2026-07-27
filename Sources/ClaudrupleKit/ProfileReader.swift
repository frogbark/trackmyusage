import Foundation

public enum ProfileError: Error, Equatable, CustomStringConvertible {
    case unreadableConfig(path: String)

    public var description: String {
        switch self {
        case .unreadableConfig(let path):
            return "could not parse \(path) as JSON"
        }
    }
}

/// Reads an instance's on-disk profile into the pure `InstanceState` the planner consumes.
///
/// Deliberately read-only and value-free: it collects key *names* so they can be
/// classified, and never the values behind them. There is no reason for a planner to hold
/// an OAuth token in memory, and not holding one removes a whole class of future mistake.
public enum ProfileReader {

    static let extensionsDirectory = "Claude Extensions"
    static let configFile = "config.json"

    public static func read(name: String, profileURL: URL) throws -> InstanceState {
        InstanceState(
            name: name,
            extensions: try readExtensions(in: profileURL),
            configKeys: try readConfigKeys(in: profileURL))
    }

    // MARK: - Extensions

    private static func readExtensions(in profileURL: URL) throws -> Set<String> {
        let dir = profileURL.appendingPathComponent(extensionsDirectory)

        // A freshly created instance has no extensions directory. That is a valid state to
        // sync *into*, so absence is emptiness rather than failure.
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])

        return Set(
            entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent))
    }

    // MARK: - Config

    private static func readConfigKeys(in profileURL: URL) throws -> Set<String> {
        let file = profileURL.appendingPathComponent(configFile)
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }

        // Malformed config is an error, not an empty result. Treating it as "no keys"
        // would let a corrupt profile look like a clean one, and sync would then report
        // nothing to do — the most misleading answer available.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw ProfileError.unreadableConfig(path: file.path) }

        return Set(dict.keys)
    }
}
