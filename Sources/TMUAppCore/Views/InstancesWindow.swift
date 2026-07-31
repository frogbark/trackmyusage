import AppKit
import SwiftUI
import TMUDesign
import TMUKit
import TMUWidgets

/// Bringing an instance to the front.
public enum Switcher {
    public static func activate(named name: String) {
        guard let instance = InstanceLocator.discover().first(where: { $0.name == name })
        else { return }
        NSWorkspace.shared.open(instance.appURL)
    }

    public static func activate(bundleID: String) {
        guard let instance = InstanceLocator.discover().first(where: { $0.bundleID == bundleID })
        else { return }
        NSWorkspace.shared.open(instance.appURL)
    }
}

/// 1g and 3b — the instances window.
///
/// Grouped by app, with only the Claude group populated. The grouping exists now because
/// Codex support is a routing change rather than a redesign, and adding the structure later
/// would mean rewriting this view rather than adding a row to it.
public struct InstancesWindow: View {

    @ObservedObject var store: TelemetryStore

    public init(store: TelemetryStore) { self.store = store }

    public var body: some View {
        VStack(spacing: 0) {
            if store.instances.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Group2(
                            label: "Claude",
                            sub: "\(store.instances.count) · claude://",
                            rows: store.instances,
                            active: store.activeInstance)
                        NewInstanceRow()
                    }
                    .padding(18)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No instances yet")
                .font(.system(size: 14, weight: .semibold))
            Text("./scripts/create-instance.sh \"Work\" --launch")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("broker owns claude:// · reclaims within ~1s")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Toggle("Notify me", isOn: $store.settings.notificationsEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
            // "Reload", not "Refresh". Refreshing an *instance* now means re-cloning its
            // bundle from the installed Claude, and a button one line below a card offering
            // `refresh-instance.sh` must not look like the same verb — this one re-reads
            // what is on disk and changes nothing.
            Button("Reload") { store.refreshInstances() }
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private struct Group2: View {
    let label: String
    let sub: String
    let rows: [TelemetryStore.InstanceRow]
    let active: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                InstanceCard(row: row, isActive: row.name == active)
            }
        }
    }
}

private struct InstanceCard: View {
    let row: TelemetryStore.InstanceRow
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: row.isPrimary ? "star.fill" : "square.stack.3d.up.fill")
                    .foregroundStyle(row.isPrimary ? Color(Ink.warn) : Color(Ink.ok))
                Text(row.name).font(.system(size: 14, weight: .semibold))
                if isActive { Capsule2(text: "active") }
                if row.freshness.needsRefresh { Capsule2(text: "out of step", tint: Ink.warn) }
                Spacer()
                Button("Open") { Switcher.activate(bundleID: row.bundleID) }
                    .controlSize(.small)
            }

            // Only when there is something to act on. A permanent "up to date" line on every
            // card is a row of text that never changes and so is never read — and the point
            // of surfacing this at all is that a clone falling behind is currently silent.
            if row.freshness.needsRefresh {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(Ink.warn))
                    // `summary`, not a second copy of the same arrow formatting. One
                    // definition of how a version comparison reads, used by the chip here
                    // and asserted by the tests.
                    Text(row.freshness.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // The command, not a button — refreshing replaces a signed bundle and
                    // refuses while the instance is running. Same reasoning as the popover
                    // banner and the new-instance row: say where it lives rather than offer
                    // a click that fails half the time.
                    Text("./scripts/refresh-instance.sh \"\(row.name)\"")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // Absence stated, never drawn as zero — the same rule the wallpaper follows.
            // An instance with no history renders no meters, and without a line saying why
            // the card is simply a name with a gap under it, which reads as a bug rather
            // than as a fact about the instance.
            if row.metrics.isEmpty {
                Text(
                    row.hasReadings
                        ? "No metered limits reported."
                        : "No readings yet — sign in to this instance to start recording."
                )
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            ForEach(row.metrics, id: \.label) { metric in
                HStack(spacing: 10) {
                    Text(metric.label)
                        .font(.system(size: 11))
                        .frame(width: 96, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Meter(
                        utilization: metric.value, state: metric.state, isStale: false,
                        height: 4)
                    Text("\(Int(metric.value))%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Text("⧉ \(row.extensionCount) extensions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                // Middle-truncated: the interesting half of a bundle id is the end.
                Text(row.bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.07), lineWidth: 1)))
    }
}

private struct NewInstanceRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
            Text("New instance").font(.system(size: 12))
            Spacer()
            // Honest about where this lives today. A button that opened a sheet which then
            // told you to use the CLI would be worse than saying so here.
            Text("./scripts/create-instance.sh")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    .white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
