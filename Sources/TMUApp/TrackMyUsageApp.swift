import SwiftUI
import TMUAppCore
import TMUDesign
import TMUKit
import TMUProviders

/// The shell: `@main`, two Scenes, and nothing else.
///
/// Everything with behaviour lives in `TMUAppCore`, which is a library and therefore
/// testable. Before the split this target had no tests at all — not because nobody wrote
/// them, but because `@testable import` of an executable target is awkward enough that
/// nobody was going to.
@main
struct TrackMyUsageApp: App {

    @StateObject private var store: TelemetryStore

    init() {
        // Before the store reads anything. The app is often the first thing launched after
        // an upgrade — the CLI may never be run at all — so it cannot assume another binary
        // migrated first.
        let receipt = Migration.runOnceIfNeeded(
            legacyKeychainService: KeychainCredentials.legacyService,
            newKeychainService: KeychainCredentials.defaultService)

        let store = TelemetryStore()
        // Surface a migration that did not finish, once. Being honestly incomplete beats
        // being quietly wrong, and the commonest case — launch agents waiting for their
        // binaries to be reinstalled — needs the user to do something.
        if let unfinished = receipt?.outcomes
            .filter({ $0.value != .done })
            .map({ "\($0.key): \($0.value.summary)" })
            .sorted()
            .first
        {
            store.note(migration: "Migration incomplete — \(unfinished)")
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        // The menu bar is the product's resting state: usage for every account and every
        // metered service visible without opening anything.
        MenuBarExtra {
            Popover(
                store: store,
                onOpenInstances: {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?
                        .makeKeyAndOrderFront(nil)
                },
                onQuit: { NSApp.terminate(nil) }
            )
            .task { Notifier.requestPermission() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Instances", id: "main") {
            InstancesWindow(store: store)
        }
        .defaultSize(width: 640, height: 460)
    }
}

/// The pill: the mark, then a percentage per account.
private struct MenuBarLabel: View {
    @ObservedObject var store: TelemetryStore

    var body: some View {
        // Zero spacing: the gap is inside the mark's bitmap, because the label ignores this
        // stack's spacing entirely. Setting both would double it.
        HStack(spacing: 0) {
            // An Image, not the view itself. A MenuBarExtra label renders Text and Image and
            // silently declines shapes — the mark drew correctly in every other context and
            // came out as an empty gap here, twice, with nothing to say why.
            if let mark = MarkGlyph(peak: peak, isStale: anyStale)
                .nsImage(trailingGap: MenuBarPill.markSpacing)
            {
                Image(nsImage: mark)
            }
            Text(title).monospacedDigit()
        }
    }

    /// Order is the model's — by name, stable. A pill whose numbers swap places as usage
    /// moves cannot be read at a glance, which is the only thing a pill is for.
    private var title: String {
        let accounts = store.model.claude
        guard !accounts.isEmpty else { return "—" }
        return accounts.map(\.display).joined(separator: " · ")
    }

    /// The worst state anywhere, which is what the third bar reports.
    private var peak: UsageState {
        let states = store.model.claude.map(\.state) + store.model.services.map(\.state)
        if states.contains(.over) { return .over }
        if states.contains(.warn) { return .warn }
        return .ok
    }

    private var anyStale: Bool {
        store.model.claude.contains(where: \.isStale)
            || store.model.services.contains(where: \.isStale)
    }
}
