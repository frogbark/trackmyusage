import Foundation

/// Executes a `MigrationPlan`.
///
/// Never throws. A migration that fails loudly at process start would make an unrelated
/// problem — a locked keychain, a launchctl that refuses — look like the app is broken.
/// Each step records why it failed, the receipt is written either way, and only an
/// all-clear marks the receipt complete, so the next launch retries exactly the step that
/// did not land rather than all of them.
public struct MigrationRunner: Sendable {

    private let home: URL
    private let files: any FileMoving
    private let keychain: any KeychainRelabeling
    private let launchctl: any LaunchctlRunning
    private let newKeychainService: String
    private let legacyKeychainService: String

    public init(
        home: URL,
        files: any FileMoving,
        keychain: any KeychainRelabeling,
        launchctl: any LaunchctlRunning,
        legacyKeychainService: String,
        newKeychainService: String
    ) {
        self.home = home
        self.files = files
        self.keychain = keychain
        self.launchctl = launchctl
        self.legacyKeychainService = legacyKeychainService
        self.newKeychainService = newKeychainService
    }

    public func run(_ plan: MigrationPlan) -> MigrationReceipt {
        var outcomes: [String: StepOutcome] = [:]
        for step in plan.steps {
            outcomes[step.rawValue] = perform(step)
        }
        return MigrationReceipt(outcomes: outcomes)
    }

    private func perform(_ step: MigrationStep) -> StepOutcome {
        do {
            switch step {
            case .keychain: return try migrateKeychain()
            case .caches: return try move(LegacyPaths.caches(home: home))
            case .wallpaperState: return try scrubWallpaperState()
            case .ownedFiles: return try moveOwnedFiles()
            case .logs: return try move(LegacyPaths.logs(home: home))
            case .agents: return try migrateAgents()
            }
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: - Steps

    private func migrateKeychain() throws -> StepOutcome {
        let count = try keychain.relabel(from: legacyKeychainService, to: newKeychainService)
        return count == 0 ? .skipped("no items under the old service") : .done
    }

    private func move(_ move: LegacyPaths.Move) throws -> StepOutcome {
        guard files.exists(move.old) else { return .skipped("nothing at the old location") }
        guard !files.exists(move.new) else {
            // Both present means a previous partial run, or two installs. Moving on top of
            // the new one would merge two histories; leave it and say so.
            return .skipped("both locations exist — left alone, merge by hand")
        }
        try files.move(move.old, to: move.new)
        return .done
    }

    private func moveOwnedFiles() throws -> StepOutcome {
        let from = LegacyPaths.instanceSupportDirectory(home: home)
        let to = LegacyPaths.supportDirectory(home: home)
        var moved = 0
        for name in LegacyPaths.ownedFilesInInstanceSupport {
            let source = from.appendingPathComponent(name)
            guard files.exists(source) else { continue }
            let destination = to.appendingPathComponent(name)
            guard !files.exists(destination) else { continue }
            try files.move(source, to: destination)
            moved += 1
        }
        return moved == 0 ? .skipped("no owned files beside the instance profiles") : .done
    }

    /// Forget a remembered wallpaper that is one of our own renders.
    ///
    /// `WallpaperOrigin.pristine` refuses to composite onto anything inside the *current*
    /// output directory. A pristine recorded before that guard existed points into the old
    /// one, which the new guard does not recognise as ours — so the daemon would happily
    /// composite the overlay onto a previous overlay, stacking scrims a little darker every
    /// five minutes, with nothing anywhere reporting an error.
    private func scrubWallpaperState() throws -> StepOutcome {
        let state = LegacyPaths.caches(home: home).new
            .appendingPathComponent("wallpaper/state.json")
        guard files.exists(state) else { return .skipped("no wallpaper state to scrub") }

        let raw = try files.read(state)
        // `try?`, not `try`: JSONSerialization throws on malformed input, and a state file
        // we cannot parse is not a migration failure. WallpaperState.load already treats
        // corruption as empty and rebuilds; reporting it as failed here would keep the
        // receipt incomplete forever and re-run every other step on every launch.
        guard
            let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
            var displays = root["displays"] as? [String: Any]
        else {
            return .skipped("wallpaper state was not in the expected shape")
        }

        let ours = [LegacyPaths.caches(home: home).old, LegacyPaths.caches(home: home).new]
            .map { $0.appendingPathComponent("wallpaper").path }

        var scrubbed = 0
        for (id, value) in displays {
            guard var display = value as? [String: Any],
                let pristine = display["pristine"] as? String
            else { continue }
            let path = URL(string: pristine)?.path ?? pristine
            guard ours.contains(where: { path.hasPrefix($0) }) else { continue }
            display.removeValue(forKey: "pristine")
            displays[id] = display
            scrubbed += 1
        }
        guard scrubbed > 0 else { return .skipped("no self-referential wallpaper recorded") }

        var updated = root
        updated["displays"] = displays
        let data = try JSONSerialization.data(
            withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try files.write(data, to: state)
        return .done
    }

    /// Relabel the launch agents, but only when there is something for them to run.
    ///
    /// The plists name binaries by absolute path, and those binaries do not exist under the
    /// new names until the user rebuilds and reinstalls. Rewriting a plist to point at a
    /// path that is not there would replace a working agent with one that fails on every
    /// launch — visibly worse than leaving the old one running. So the step checks first
    /// and skips with an instruction.
    private func migrateAgents() throws -> StepOutcome {
        var migrated = 0
        var waiting: [String] = []

        for agent in LegacyPaths.agents {
            let old = agent.oldPlist(home: home)
            guard files.exists(old) else { continue }

            let rewritten = Self.rewrite(String(data: try files.read(old), encoding: .utf8) ?? "")
            guard let program = Self.firstProgramArgument(in: rewritten) else {
                waiting.append("\(agent.newLabel) (could not read its program path)")
                continue
            }
            guard files.exists(URL(fileURLWithPath: program)) else {
                waiting.append(agent.newLabel)
                continue
            }

            try launchctl.bootout(label: agent.oldLabel)
            try files.write(Data(rewritten.utf8), to: agent.newPlist(home: home))
            try launchctl.bootstrap(plist: agent.newPlist(home: home))
            try launchctl.enable(label: agent.newLabel)
            try files.remove(old)
            migrated += 1
        }

        if !waiting.isEmpty {
            return .skipped(
                """
                \(waiting.joined(separator: ", ")) still points at a binary that does not \
                exist yet — install the apps, then run `tmud --migrate`. A skip is not a \
                failure, so nothing retries this on its own.
                """)
        }
        return migrated == 0 ? .skipped("no legacy agents installed") : .done
    }

    // MARK: - Plist rewriting

    /// Rename inside a plist, leaving the frozen install directory alone.
    ///
    /// `/Applications/Claudruple` is where clones are registered and cannot move, but the
    /// broker bundle *inside* it is renamed — so the same string contains one part that
    /// changes and one that must not. Freeze the directory first, rename, then thaw.
    static func rewrite(_ plist: String) -> String {
        let frozen = "\u{0}APPS\u{0}"
        var text = plist.replacingOccurrences(of: "/Applications/Claudruple", with: frozen)
        for (old, new) in [
            ("com.claudruple.link", "com.trackmyusage.link"),
            ("com.claudruple.wallpaper", "com.trackmyusage.wallpaper"),
            ("Claudruple Link", "TrackMyUsage Link"),
            ("claudrupled", "tmud"),
            ("Library/Logs/Claudruple", "Library/Logs/TrackMyUsage"),
            ("Library/Caches/Claudruple", "Library/Caches/TrackMyUsage"),
        ] {
            text = text.replacingOccurrences(of: old, with: new)
        }
        return text.replacingOccurrences(of: frozen, with: "/Applications/Claudruple")
    }

    /// The executable a plist runs — the first `<string>` inside `ProgramArguments`.
    static func firstProgramArgument(in plist: String) -> String? {
        guard let range = plist.range(of: "<key>ProgramArguments</key>") else { return nil }
        let rest = plist[range.upperBound...]
        guard
            let open = rest.range(of: "<string>"),
            let close = rest[open.upperBound...].range(of: "</string>")
        else { return nil }
        return String(rest[open.upperBound..<close.lowerBound])
    }
}
