import ClaudrupleKit
import Foundation

// Argument parsing is hand-rolled. There are four subcommands and two flags; pulling in
// swift-argument-parser would add a dependency to a tool whose selling point is that it
// builds with nothing but a Swift toolchain.

let version = "0.1.0"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let usage = """
    claudruple \(version) — multi-account Claude Desktop

    USAGE
      claudruple instances                      list installed instances
      claudruple capture [name]                 write a manifest from what is installed
      claudruple plan <manifest.yaml> [--prune] show what would change
      claudruple apply <manifest.yaml> [--prune]

    NOTES
      Removal always requires --prune, even when the manifest declares `policy: exact`.
      Without it, exact behaves as additive.
    """

// MARK: - Rendering

func describe(_ plan: SyncPlan, for name: String, policy: DriftPolicy) {
    print("\n  \(name)  [\(policy.rawValue)]")

    if plan.isEmpty {
        print("    already converged")
    }
    for id in plan.installs { print("    + \(id)") }
    for id in plan.removals { print("    - \(id)") }

    if !plan.refused.isEmpty {
        // Shown rather than silently dropped: a user who cannot see what was skipped
        // cannot distinguish a safety refusal from a bug.
        let account = plan.refused.filter { $0.scope == .account }
        if !account.isEmpty {
            print("    · \(account.count) account-scoped key(s) not synced: "
                + account.prefix(3).map(\.key).joined(separator: ", ")
                + (account.count > 3 ? ", …" : ""))
        }
    }
}

// MARK: - Commands

func cmdInstances() {
    let found = InstanceLocator.discover()
    guard !found.isEmpty else { return print("no Claude instances found") }

    for inst in found {
        let state = try? ProfileReader.read(name: inst.name, profileURL: inst.profileURL)
        let count = state.map { "\($0.extensions.count) extension(s)" } ?? "profile unreadable"
        print("  \(inst.name)\(inst.isPrimary ? "  (primary)" : "")")
        print("    bundle   \(inst.bundleID)")
        print("    profile  \(inst.profileURL.path)")
        print("    \(count)")
    }
}

func cmdCapture(_ name: String?) {
    let found = InstanceLocator.discover()
        .filter { name == nil || $0.name == name }
    guard !found.isEmpty else { die("no instance named '\(name ?? "")'") }

    let specs = found.map { inst -> InstanceSpec in
        let state = try? ProfileReader.read(name: inst.name, profileURL: inst.profileURL)
        return InstanceSpec(
            name: inst.name,
            extensions: (state?.extensions).map { $0.sorted() } ?? [],
            keep: [],
            policy: .additive)
    }
    print(Manifest.render(specs), terminator: "")
}

func cmdPlanOrApply(path: String, prune: Bool, apply: Bool) {
    let manifest: Manifest
    do {
        manifest = try Manifest.parse(contentsOf: URL(fileURLWithPath: path))
    } catch let e as ManifestError {
        die(e.description)
    } catch {
        die("could not read \(path): \(error.localizedDescription)")
    }

    let installed = Dictionary(
        uniqueKeysWithValues: InstanceLocator.discover().map { ($0.name, $0) })

    for spec in manifest.instances {
        guard let inst = installed[spec.name] else {
            print("\n  \(spec.name)\n    not installed — skipped")
            continue
        }
        guard let state = try? ProfileReader.read(name: spec.name, profileURL: inst.profileURL)
        else {
            print("\n  \(spec.name)\n    profile unreadable — skipped")
            continue
        }

        let effective = spec.policy.effective(pruneAuthorized: prune)
        describe(SyncPlan.between(spec: spec, state: state, policy: effective),
                 for: spec.name, policy: effective)

        if spec.policy == .exact && !prune {
            print("    note: manifest declares exact; pass --prune to authorise removal")
        }
    }

    if apply {
        print("\n  apply is not implemented yet — this was a plan.")
        exit(2)
    }
    print("")
}

// MARK: - Entry

var args = Array(CommandLine.arguments.dropFirst())
let prune = args.contains("--prune")
args.removeAll { $0 == "--prune" }

switch args.first {
case "instances":
    cmdInstances()
case "capture":
    cmdCapture(args.count > 1 ? args[1] : nil)
case "plan", "apply":
    guard args.count > 1 else { die("\(args[0]) needs a manifest path") }
    cmdPlanOrApply(path: args[1], prune: prune, apply: args[0] == "apply")
case "--version":
    print(version)
case "help", "--help", "-h", nil:
    print(usage)
default:
    die("unknown command '\(args[0])'\n\n\(usage)")
}
