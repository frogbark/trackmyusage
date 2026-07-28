import Foundation

/// The three ways migration touches the world. Injected so the runner can be tested against
/// failures that are impractical to stage for real — a locked keychain, a launchctl that
/// refuses, a move onto a full disk.

public protocol FileMoving: Sendable {
    func exists(_ url: URL) -> Bool
    func move(_ from: URL, to: URL) throws
    func read(_ url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
    func createDirectory(_ url: URL) throws
}

public protocol KeychainRelabeling: Sendable {
    /// Move every item from one service to another **without decrypting anything**.
    ///
    /// This is the whole reason the protocol exists rather than a copy-then-delete: reading
    /// a secret to rewrite it would pull provider API keys into process memory, which this
    /// codebase otherwise never does. Relabelling updates an attribute and never asks for
    /// `kSecValueData`.
    ///
    /// Returns the number of items relabelled.
    func relabel(from oldService: String, to newService: String) throws -> Int
}

public protocol LaunchctlRunning: Sendable {
    func bootout(label: String) throws
    func bootstrap(plist: URL) throws
    func enable(label: String) throws
}

// MARK: - Real implementations

public struct SystemFileMover: FileMoving {
    public init() {}

    // FileManager is not Sendable, so it is fetched per call rather than stored. `.default`
    // is documented as safe to use from multiple threads for these operations, and this
    // type must stay Sendable to be injected into a Sendable runner.
    private var fm: FileManager { .default }

    public func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    public func move(_ from: URL, to: URL) throws {
        try createDirectory(to.deletingLastPathComponent())
        try fm.moveItem(at: from, to: to)
    }

    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    public func write(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    public func remove(_ url: URL) throws { try fm.removeItem(at: url) }

    public func createDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

#if canImport(Darwin)

import Darwin

public struct SystemLaunchctl: LaunchctlRunning {
    public init() {}

    private var domain: String { "gui/\(getuid())" }

    public func bootout(label: String) throws {
        // A label that is not loaded is the expected case on a fresh install, not an error.
        _ = try? run(["bootout", "\(domain)/\(label)"])
    }

    public func bootstrap(plist: URL) throws { _ = try run(["bootstrap", domain, plist.path]) }

    public func enable(label: String) throws { _ = try run(["enable", "\(domain)/\(label)"]) }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            throw MigrationError.launchctl(arguments.joined(separator: " "), text.trimmed)
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

#endif

public enum MigrationError: Error, Equatable, CustomStringConvertible {
    case launchctl(String, String)
    case keychain(Int)

    public var description: String {
        switch self {
        case .launchctl(let command, let output):
            return "launchctl \(command) failed\(output.isEmpty ? "" : ": \(output)")"
        case .keychain(let status):
            return "keychain error \(status)"
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
