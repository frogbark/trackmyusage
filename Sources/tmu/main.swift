import AppKit
import Foundation
import TMUKit
import TMUProviders

// Argument parsing is hand-rolled. There are four subcommands and two flags; pulling in
// swift-argument-parser would add a dependency to a tool whose selling point is that it
// builds with nothing but a Swift toolchain.

let version = "0.1.0"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let usage = """
    tmu \(version) — multi-account Claude Desktop

    USAGE
      tmu instances                      list installed instances
      tmu usage                          plan usage per account
      tmu steer [--yes]                  which account to work in
      tmu provider <list|add|probe|check>  metered service accounts
      tmu capture [name]                 write a manifest from what is installed
      tmu plan <manifest.yaml>           show what would change (read-only)
      tmu apply <manifest.yaml>          make it so

    FLAGS
      --prune            authorise removals. Required even when the manifest declares
                         `policy: exact`; without it, exact behaves as additive.
      --from <instance>  copy extension payloads from this instance
                         (default: whichever instance covers the most of what is needed)
      --with-settings    also copy Claude Extensions Settings. OFF by default because
                         those files hold API keys and filesystem grants.
      --active <name>    treat this instance as the one in use (steer)
      --yes              actually perform the switch (steer)

    NOTES
      apply refuses to write to a running instance — Claude rewrites its extension
      registry on exit and would discard the changes. Quit the target first.
    """

/// Pad to a column width by character count.
///
/// `String(format: "%-12s", …)` pads by *bytes*, so a single em dash or accented character
/// silently corrupts both the alignment and the text itself.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

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
            print(
                "    · \(account.count) account-scoped key(s) not synced: "
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

func bar(_ pct: Double, width: Int = 24) -> String {
    let filled = max(0, min(width, Int((pct / 100 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

func relative(_ date: Date, from now: Date) -> String {
    let h = date.timeIntervalSince(now) / 3600
    if h < 1 { return "in \(Int((h * 60).rounded()))m" }
    if h < 48 { return "in \(String(format: "%.1f", h))h" }
    return "in \(Int((h / 24).rounded()))d"
}

func loadAccounts() -> [(DiscoveredInstance, AccountUsage)] {
    InstanceLocator.discover().compactMap { inst in
        let file = inst.profileURL.appendingPathComponent("plan-usage-history.json")
        guard let h = try? UsageHistory.parse(contentsOf: file), !h.samples.isEmpty
        else { return nil }
        return (
            inst,
            AccountUsage(
                instanceName: inst.name, bundleID: inst.bundleID, history: h)
        )
    }
}

/// Which account is actually being worked in.
///
/// Frontmost is useless from a terminal — that is Terminal. Instead infer it from the data:
/// the instance whose 5-hour window is climbing fastest is the one consuming budget right
/// now. `--active` overrides when the guess is wrong.
func inferActive(_ accounts: [AccountUsage], now: Date, override: String?) -> String? {
    if let override { return override }
    return
        accounts
        .compactMap { a -> (String, Double)? in
            guard let f = a.history.forecast(for: .fiveHour, now: now),
                let rate = f.pointsPerHourOrNil, rate > 0
            else { return nil }
            return (a.instanceName, rate)
        }
        .max { $0.1 < $1.1 }?.0
}

func printAdvice(_ advice: SteeringAdvice, active: String?) {
    let mark: String
    switch advice.urgency {
    case .none: mark = "·"
    case .approaching: mark = "!"
    case .exhausted: mark = "!!"
    }
    print("\n  \(mark) \(active.map { "\($0): " } ?? "")\(advice.reason)")
}

func cmdSteer(activeOverride: String?, confirmed: Bool) {
    let now = Date()
    let loaded = loadAccounts()
    guard !loaded.isEmpty else { return print("no usage history found") }

    let accounts = loaded.map(\.1)
    let active = inferActive(accounts, now: now, override: activeOverride)
    let advice = Steering.advise(accounts: accounts, activeInstance: active, now: now)

    for (inst, a) in loaded {
        let b = a.binding(now: now)
        let tag = inst.name == active ? " (active)" : ""
        print(
            "  \(pad(inst.name, 14)) \(pad(b?.metric.displayName ?? "—", 10))"
                + String(format: " %5.1f%%  headroom %.0f", b?.value ?? 0, a.headroom(now: now))
                + tag)
    }
    printAdvice(advice, active: active)

    guard let target = advice.recommended,
        let dest = loaded.first(where: { $0.0.name == target })?.0
    else { return print("") }

    guard confirmed else {
        // Confirmation is the default: switching accounts mid-task is disruptive, and a
        // tool that reshuffles windows unprompted stops being trusted.
        print("    run with --yes to bring \(target) to the front\n")
        return
    }
    NSWorkspace.shared.open(dest.appURL)
    print("    switched to \(target)\n")
}

func cmdUsage() {
    let now = Date()
    var any = false

    for inst in InstanceLocator.discover() {
        let file = inst.profileURL.appendingPathComponent("plan-usage-history.json")
        guard let history = try? UsageHistory.parse(contentsOf: file),
            let latest = history.samples.last
        else { continue }
        any = true

        let age = Int(now.timeIntervalSince(latest.timestamp) / 60)
        print("\n  \(inst.name)   (updated \(age)m ago, \(history.samples.count) samples)")

        // Latest sample first, so a metric that stopped being reported does not linger.
        for metric in latest.metrics.keys.sorted(by: { $0.displayName < $1.displayName }) {
            guard let value = latest.metrics[metric] else { continue }
            var line =
                "    \(pad(metric.displayName, 20)) \(bar(value)) "
                + String(format: "%5.1f%%", value)

            if let f = history.forecast(for: metric, now: now) {
                if f.isExhausted {
                    line += "   EXHAUSTED"
                } else if let at = f.exhaustionDate {
                    line += String(
                        format: "   +%.1f/h, full %@", f.pointsPerHour, relative(at, from: now))
                } else if f.pointsPerHourOrNil == nil {
                    // Distinguish "no trend measurable" from "trend is flat" — they look
                    // identical in a bar and mean very different things.
                    line += "   (no recent trend)"
                }
            }
            print(line)
        }
    }
    if !any { print("no usage history found") }
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
    return
        candidates
        .map { inst -> (DiscoveredInstance, Int) in
            let have =
                (try? ProfileReader.read(name: inst.name, profileURL: inst.profileURL))?
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

        guard
            let src = resolveSource(
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

            print(
                "    applied: \(result.installed.count) installed, "
                    + "\(result.removed.count) removed")
            for s in result.skipped { print("    · skipped \(s.id) — \(s.reason)") }
            if let b = result.backupURL { print("    backup: \(b.path)") }
            if !withSettings && !result.installed.isEmpty {
                // Say it plainly: an extension that needs a key arrives inert, and a user
                // who does not know that will read it as a broken install.
                print(
                    "    note: extension settings were not copied — configure keys per "
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

var activeOverride: String?
if let i = args.firstIndex(of: "--active") {
    guard i + 1 < args.count else { die("--active needs an instance name") }
    activeOverride = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let confirmed = args.contains("--yes")

var sourceOverride: String?
if let i = args.firstIndex(of: "--from") {
    guard i + 1 < args.count else { die("--from needs an instance name") }
    sourceOverride = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
args.removeAll { $0 == "--prune" || $0 == "--with-settings" || $0 == "--yes" }

// Any of the three binaries can be the first thing run after an upgrade, so each migrates.
// Skipped for help and --version: those must stay instant and must not provoke a keychain
// prompt for somebody who only wanted to read the usage text.
if let command = args.first, !["help", "--help", "-h", "--version"].contains(command) {
    if let receipt = Migration.runOnceIfNeeded(
        legacyKeychainService: KeychainCredentials.legacyService,
        newKeychainService: KeychainCredentials.defaultService)
    {
        // Only the incomplete ones are worth a line. A migration that worked is not news,
        // and printing it before every command would train people to ignore the output.
        for (step, outcome) in receipt.outcomes.sorted(by: { $0.key < $1.key })
        where outcome != .done {
            FileHandle.standardError.write(Data("migration: \(step) \(outcome.summary)\n".utf8))
        }
    }
}

switch args.first {
case "instances":
    cmdInstances()
case "usage":
    cmdUsage()
case "steer":
    cmdSteer(activeOverride: activeOverride, confirmed: confirmed)
case "provider":
    ProviderCommands.run(Array(args.dropFirst()))
case "assets":
    // Brand assets are generated from geometry rather than committed as files, so the mark
    // on the website, the app icon and the menu bar glyph cannot drift apart.
    AssetCommands.run(Array(args.dropFirst()))
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
