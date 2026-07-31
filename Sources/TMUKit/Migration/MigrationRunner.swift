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
    private let desktop: any DesktopRestoring
    private let newKeychainService: String
    private let legacyKeychainService: String

    public init(
        home: URL,
        files: any FileMoving,
        keychain: any KeychainRelabeling,
        launchctl: any LaunchctlRunning,
        desktop: any DesktopRestoring,
        legacyKeychainService: String,
        newKeychainService: String
    ) {
        self.home = home
        self.files = files
        self.keychain = keychain
        self.launchctl = launchctl
        self.desktop = desktop
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
            case .wallpaperTeardown: return try tearDownWallpaper()
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

    /// Take the wallpaper feature off this machine.
    ///
    /// Deleting the code is not the same as removing the feature from an install that has it.
    /// Such a machine has a LaunchAgent on a 300s timer invoking a `tmud` that no longer
    /// exists — failing silently every five minutes, which is precisely the failure mode
    /// install-wallpaper-agent.sh warned about — and a rendered PNG set as its desktop
    /// background. macOS keeps no wallpaper history, so without this step that render is
    /// permanent and the user has no way to discover what it replaced.
    ///
    /// So the migration *grew* a step where it might have lost one. Three things, in an order
    /// that matters: stop the agent first, or it repaints the desktop between the restore and
    /// the delete; restore before deleting the renders, or the file being restored from is
    /// gone; and only then remove the renders.
    ///
    /// Idempotent throughout. Every part reports what it actually did, so a partial run — the
    /// plist gone but the desktop not yet restored — completes on the next launch rather than
    /// being mistaken for finished.
    private func tearDownWallpaper() throws -> StepOutcome {
        var did: [String] = []

        // 1. Stop it. Both labels: an install may have been renamed before the feature was
        // dropped, or may not. Booting out a label that is not loaded is not an error.
        for label in LegacyPaths.wallpaperAgentLabels {
            let plist = LegacyPaths.launchAgentsDirectory(home: home)
                .appendingPathComponent("\(label).plist")
            try launchctl.bootout(label: label)
            guard files.exists(plist) else { continue }
            try files.remove(plist)
            did.append("stopped \(label)")
        }

        // 2. Put the desktop back, from whichever support directory still holds the record.
        if let restored = try restoreRecordedWallpaper() {
            did.append(restored)
        }

        // 3. Only now delete the renders.
        for directory in LegacyPaths.renderedWallpaperDirectories(home: home)
        where files.exists(directory) {
            try files.remove(directory)
            did.append("removed \(directory.lastPathComponent) renders")
        }

        return did.isEmpty ? .skipped("no wallpaper install to remove") : .done
    }

    /// Restore the background the wallpaper agent replaced, if it is still there to restore.
    ///
    /// Returns nil when there was nothing recorded, and a note when there was a record but the
    /// file it names has since been deleted. That second case is reported rather than treated
    /// as a failure: a person who deleted their old wallpaper is not a migration that went
    /// wrong, and failing here would re-run every other step on the next launch forever.
    private func restoreRecordedWallpaper() throws -> String? {
        guard
            let record = LegacyPaths.recordedOriginalWallpaper(home: home)
                .first(where: files.exists)
        else { return nil }

        let path =
            String(data: try files.read(record), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try files.remove(record)

        guard !path.isEmpty else { return "no original was recorded" }
        let original = URL(fileURLWithPath: path)
        guard files.exists(original) else {
            return
                "recorded original is gone (\(original.lastPathComponent)) — set one in System Settings"
        }

        try desktop.setDesktopImage(original)
        return "restored \(original.lastPathComponent)"
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
