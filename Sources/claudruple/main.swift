import AppKit
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
      claudruple plan <manifest.yaml>           show what would change (read-only)
      claudruple apply <manifest.yaml>          make it so

    FLAGS
      --prune            authorise removals. Required even when the manifest declares
                         `policy: exact`; without it, exact behaves as additive.
      --from <instance>  copy extension payloads from this instance
                         (default: whichever instance covers the most of what is needed)
      --with-settings    also copy Claude Extensions Settings. OFF by default because
                         those files hold API keys and filesystem grants.

    NOTES
      apply refuses to write to a running instance — Claude rewrites its extension
      registry on exit and would discard the changes. Quit the target first.
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

/// A plan says *install X* but not *from where* — extension payloads have to be copied
/// from an instance that already has them. Pick the instance covering the most of what is
/// needed, so the common case (capture from one instance, apply to another) needs no flag,
/// and report the choice rather than making it invisibly.
func resolveSource(
    for installs: [String], excluding targetName: String, override: String?
) -> DiscoveredInstance? {
    let candidates = InstanceLocator.discover().filter { $0.name != targetName }

    if let override {
        return candidates.first { $0.name == override }
    }
    guard !installs.isEmpty else { return candidates.first }

    let wanted = Set(installs)
    return candidates
        .map { inst -> (DiscoveredInstance, Int) in
            let have = (try? ProfileReader.read(name: inst.name, profileURL: inst.profileURL))?
                .extensions ?? []
            return (inst, wanted.intersection(have).count)
        }
        .filter { $0.1 > 0 }
        .max { $0.1 < $1.1 }?.0
}

func runningState(_ bundleID: String) -> RunningState {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        ? .stopped : .running
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
        let plan = SyncPlan.between(spec: spec, state: state, policy: effective)
        describe(plan, for: spec.name, policy: effective)

        if spec.policy == .exact && !prune {
            print("    note: manifest declares exact; pass --prune to authorise removal")
        }
        guard apply, !plan.isEmpty else { continue }

        // Refuse rather than write under a live app: Claude reads its extension list at
        // startup and rewrites the registry on exit, so anything written now is discarded.
        guard runningState(inst.bundleID) == .stopped else {
            print("    ! \(spec.name) is running — quit it and re-run; nothing was written")
            continue
        }

        guard let src = resolveSource(
            for: plan.installs, excluding: spec.name, override: sourceOverride)
        else {
            print("    ! no instance holds the extensions to install; nothing was written")
            continue
        }
        if !plan.installs.isEmpty { print("    source: \(src.name)") }

        var options = SyncApplier.Options()
        options.includeSettings = withSettings

        do {
            let result = try SyncApplier.apply(
                plan: plan, from: src.profileURL, to: inst.profileURL,
                targetName: spec.name, running: .stopped, options: options)

            print("    applied: \(result.installed.count) installed, "
                + "\(result.removed.count) removed")
            for s in result.skipped { print("    · skipped \(s.id) — \(s.reason)") }
            if let b = result.backupURL { print("    backup: \(b.path)") }
            if !withSettings && !result.installed.isEmpty {
                // Say it plainly: an extension that needs a key arrives inert, and a user
                // who does not know that will read it as a broken install.
                print("    note: extension settings were not copied — configure keys per "
                    + "account (--with-settings overrides, and copies credentials)")
            }
        } catch let e as ApplyError {
            print("    ! \(e.description)")
        } catch {
            print("    ! \(error.localizedDescription)")
        }
    }
    print("")
}

// MARK: - Entry

var args = Array(CommandLine.arguments.dropFirst())

let prune = args.contains("--prune")
let withSettings = args.contains("--with-settings")

var sourceOverride: String?
if let i = args.firstIndex(of: "--from") {
    guard i + 1 < args.count else { die("--from needs an instance name") }
    sourceOverride = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
args.removeAll { $0 == "--prune" || $0 == "--with-settings" }

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
