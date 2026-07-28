import Foundation

extension Manifest {

    /// Render specs as `claudruple.yaml`.
    ///
    /// Hand-written rather than dumped through Yams so the output carries the comments
    /// that make a shared manifest legible. This file is the artifact people commit and
    /// read in a diff; a machine-serialised blob would technically round-trip and be
    /// worse at its actual job.
    public static func render(_ specs: [InstanceSpec]) -> String {
        var out = """
            # claudruple.yaml — declarative Claude Desktop instance configuration.
            #
            #   claudruple plan  <this file>            show what would change
            #   claudruple apply <this file>            install what is missing
            #   claudruple apply <this file> --prune    also remove unmanaged extensions
            #
            # policy: additive (default) installs but never removes.
            # policy: exact converges exactly — but removal still requires --prune, so a
            # manifest from someone else's repo can never delete your extensions on its own.
            # keep: names extensions that survive exact.
            version: \(supportedVersion)
            instances:

            """

        for spec in specs {
            out += "  - name: \(quoted(spec.name))\n"
            out += "    policy: \(spec.policy.rawValue)\n"
            out += list("extensions", spec.extensions)
            out += list("keep", spec.keep)
            out += "\n"
        }
        return out
    }

    private static func list(_ label: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "    \(label): []\n" }
        return "    \(label):\n" + values.map { "      - \(quoted($0))\n" }.joined()
    }

    /// Quote anything YAML would otherwise reinterpret.
    ///
    /// Instance names come from `CFBundleDisplayName` and are user-chosen: "Claude Two"
    /// is fine bare, but a user who names an instance "Yes" or "12345" would get a
    /// boolean or an integer back, and the mismatch would surface far from its cause.
    private static func quoted(_ value: String) -> String {
        let reserved: Set<String> = [
            "true", "false", "yes", "no", "on", "off", "null", "~", "",
        ]
        let needsQuoting =
            reserved.contains(value.lowercased())
            || Double(value) != nil
            || value.contains(":")
            || value.contains("#")
            || value.first == " "
            || value.last == " "

        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
