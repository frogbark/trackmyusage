import Foundation
import Yams

/// Everything that can be wrong with a manifest, stated precisely enough to fix.
///
/// Parsing rejects ambiguity rather than guessing. A manifest is shared and re-applied on
/// machines its author never sees, so silently doing *something* with malformed input is
/// worse than refusing.
public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case notAMapping
    case unsupportedVersion(Int)
    case missingName(index: Int)
    case duplicateInstance(String)
    case unknownParent(instance: String, parent: String)
    case circularInheritance(chain: [String])
    case invalidPolicy(instance: String, value: String)

    public var description: String {
        switch self {
        case .notAMapping:
            return "manifest must be a YAML mapping with a top-level `instances:` key"
        case .unsupportedVersion(let v):
            return
                "unsupported manifest version \(v); this build understands version \(Manifest.supportedVersion)"
        case .missingName(let i):
            return "instance at position \(i) has no `name:`"
        case .duplicateInstance(let n):
            return "duplicate instance name '\(n)'"
        case .unknownParent(let instance, let parent):
            return "'\(instance)' inherits from '\(parent)', which is not defined"
        case .circularInheritance(let chain):
            return "circular inheritance: \(chain.joined(separator: " -> "))"
        case .invalidPolicy(let instance, let value):
            let valid = DriftPolicy.allCases.map(\.rawValue).joined(separator: ", ")
            return "'\(instance)' has unknown policy '\(value)'; expected one of: \(valid)"
        }
    }
}

/// A parsed `claudruple.yaml`.
public struct Manifest: Sendable, Equatable {
    public static let supportedVersion = 1

    public let version: Int
    /// Instances with inheritance already resolved, so consumers never walk the graph.
    public let instances: [InstanceSpec]

    public static func parse(_ yaml: String) throws -> Manifest {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ManifestError.notAMapping
        }

        let version = root["version"] as? Int ?? supportedVersion
        guard version == supportedVersion else {
            throw ManifestError.unsupportedVersion(version)
        }

        let raw = try parseRawInstances(root["instances"] as? [Any] ?? [])
        return Manifest(version: version, instances: try resolve(raw))
    }

    public static func parse(contentsOf url: URL) throws -> Manifest {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public func instance(named name: String) -> InstanceSpec? {
        instances.first { $0.name == name }
    }

    // MARK: - Parsing

    /// An instance as written, before inheritance is applied.
    private struct RawInstance {
        let name: String
        let inherits: String?
        let extensions: [String]
        let keep: [String]
        let policy: DriftPolicy
    }

    private static func parseRawInstances(_ list: [Any]) throws -> [RawInstance] {
        var seen = Set<String>()
        var result: [RawInstance] = []

        for (i, entry) in list.enumerated() {
            guard let dict = entry as? [String: Any],
                let name = dict["name"] as? String, !name.isEmpty
            else { throw ManifestError.missingName(index: i) }

            guard seen.insert(name).inserted else {
                throw ManifestError.duplicateInstance(name)
            }

            let policy: DriftPolicy
            if let rawPolicy = dict["policy"] as? String {
                guard let parsed = DriftPolicy(rawValue: rawPolicy) else {
                    throw ManifestError.invalidPolicy(instance: name, value: rawPolicy)
                }
                policy = parsed
            } else {
                policy = .additive
            }

            result.append(
                RawInstance(
                    name: name,
                    inherits: dict["inherits"] as? String,
                    extensions: stringList(dict["extensions"]),
                    keep: stringList(dict["keep"]),
                    policy: policy))
        }
        return result
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    // MARK: - Inheritance

    /// Flatten `inherits:` into concrete specs.
    ///
    /// Resolution is by name across the whole manifest, so declaration order is
    /// irrelevant — a manifest is a set, not a sequence.
    private static func resolve(_ raw: [RawInstance]) throws -> [InstanceSpec] {
        let byName = Dictionary(uniqueKeysWithValues: raw.map { ($0.name, $0) })
        return try raw.map { try flatten($0, in: byName) }
    }

    private static func flatten(
        _ instance: RawInstance,
        in byName: [String: RawInstance]
    ) throws -> InstanceSpec {
        var extensions = Set<String>()
        var keep = Set<String>()

        // Walk to the root, unioning as we go. `visited` turns what would otherwise be an
        // infinite loop into a precise error — a hang is the worst possible failure here,
        // because it gives the user nothing to act on.
        var visited: [String] = []
        var cursor: RawInstance? = instance

        while let node = cursor {
            if visited.contains(node.name) {
                throw ManifestError.circularInheritance(chain: visited + [node.name])
            }
            visited.append(node.name)

            extensions.formUnion(node.extensions)
            keep.formUnion(node.keep)

            guard let parentName = node.inherits else { break }
            guard let parent = byName[parentName] else {
                throw ManifestError.unknownParent(instance: node.name, parent: parentName)
            }
            cursor = parent
        }

        // Policy is deliberately NOT inherited: it is a per-instance safety decision, and
        // silently inheriting `exact` would let a parent make a child destructive without
        // the child's author noticing.
        return InstanceSpec(
            name: instance.name,
            extensions: extensions.sorted(),
            keep: keep.sorted(),
            policy: instance.policy)
    }
}
