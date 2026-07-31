import SwiftUI
import TMUDesign
import TMUTelemetry
import TMUWidgets

/// 1f/3c — the menu bar panel.
///
/// Grouped rather than one flat list. The old panel showed Claude accounts only, because the
/// app could not see providers at all; now that it can, seventeen services and two accounts
/// in one column would bury the thing you opened it for.
public struct Popover: View {

    @ObservedObject var store: TelemetryStore
    var onOpenInstances: () -> Void
    var onOpenProviders: () -> Void
    var onQuit: () -> Void

    public init(
        store: TelemetryStore,
        onOpenInstances: @escaping () -> Void,
        onOpenProviders: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenInstances = onOpenInstances
        self.onOpenProviders = onOpenProviders
        self.onQuit = onQuit
    }

    /// Services shown before the rest are collapsed.
    static let visibleServices = 5

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = store.migrationNotice {
                MigrationBanner(text: notice) { store.dismissMigrationNotice() }
            }

            if !store.outOfStepInstances.isEmpty {
                OutOfStepInstancesBanner(names: store.outOfStepInstances)
            }

            if store.model.claude.isEmpty && store.model.services.isEmpty {
                Text("No readings yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if !store.model.claude.isEmpty {
                Section(title: "Claude") {
                    ForEach(store.model.claude, id: \.name) { row in
                        AccountRowView(row: row, isActive: row.name == store.activeInstance)
                    }
                }
            }

            if let advice = store.advice, let target = advice.recommended {
                SteeringBanner(reason: advice.reason, target: target)
            }

            if !store.model.services.isEmpty {
                Section(title: "Services", trailing: "nearest limit first") {
                    // Ranked here, at the point of use, rather than in the model. The model's
                    // order is stable by name so the wallpaper does not reshuffle every five
                    // minutes; this list is short and read top-down, so ranking earns its
                    // keep. Same data, two orders, one source.
                    let ranked = store.model.services.sorted {
                        let left = $0.utilization ?? -1
                        let right = $1.utilization ?? -1
                        return left == right ? $0.name < $1.name : left > right
                    }
                    ForEach(ranked.prefix(Self.visibleServices), id: \.name) { row in
                        ServiceRowView(row: row)
                    }
                    if ranked.count > Self.visibleServices {
                        Text("\(ranked.count - Self.visibleServices) more…")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Button("Instances…", action: onOpenInstances)
                Button("Providers…", action: onOpenProviders)
                // "Reload", for the same reason the instances window's button was renamed:
                // this re-reads what is already there, while `refresh-instance.sh` — offered
                // by the banner a few lines above — replaces a signed application bundle.
                // Two buttons a centimetre apart must not share a verb for those.
                Button("Reload") {
                    store.refreshInstances()
                    store.refreshProviders()
                }
                Spacer()
                Button("Quit", action: onQuit)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 358)
    }
}

// MARK: - Pieces

struct Section<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

struct AccountRowView: View {
    let row: TelemetryModel.AccountRow
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.name).font(.system(size: 14, weight: .semibold))
                if isActive { Capsule2(text: "active") }
                Spacer()
                Text(row.display)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(Freshness.ink(for: row.state, stale: row.isStale)))
            }
            Meter(utilization: row.utilization, state: row.state, isStale: row.isStale, height: 5)
            if let window = row.windowLabel {
                Text(window).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ServiceRowView: View {
    let row: TelemetryModel.ServiceRow

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(Freshness.ink(for: row.state, stale: row.isStale)))
                .frame(width: 7, height: 7)
            Text(row.name)
                .font(.system(size: 12))
                .frame(width: 88, alignment: .leading)
                .lineLimit(1)
            Meter(utilization: row.utilization, state: row.state, isStale: row.isStale, height: 4)
            Text(row.display)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(row.state == .nodata ? .tertiary : .primary)
        }
    }
}

/// A bar, or nothing.
///
/// Nothing when there is no utilisation — revenue has no ceiling and a failed provider has
/// no reading, and an empty track beside either is a gauge showing zero.
struct Meter: View {
    let utilization: Double?
    let state: UsageState
    let isStale: Bool
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            if let utilization {
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.13))
                    Capsule()
                        .fill(Color(Freshness.ink(for: state, stale: isStale)))
                        .frame(width: geometry.size.width * min(max(utilization, 0), 100) / 100)
                }
            }
        }
        .frame(height: height)
    }
}

struct Capsule2: View {
    let text: String
    /// Optional, and nil means the neutral chip this started as — so "active", which is a
    /// statement of fact rather than a condition, keeps looking like one and only the
    /// chips that want attention take a colour from the palette.
    var tint: Hex?

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    tint.map { Color($0).opacity(0.18) } ?? Color.primary.opacity(0.10))
            )
            .foregroundStyle(tint.map { Color($0) } ?? Color.secondary)
    }
}

/// Offered, never automatic. Switching accounts behind someone's back is the fastest way to
/// make a tool untrustworthy.
struct SteeringBanner: View {
    let reason: String
    let target: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(Color(Ink.warn))
            VStack(alignment: .leading, spacing: 8) {
                Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button("Switch to \(target)") { Switcher.activate(named: target) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(Ink.warn).opacity(0.12)))
    }
}

/// Says that one or more clones are on a different build from the installed Claude.
///
/// Not dismissible, unlike the migration notice. That one reports something that already
/// finished; this reports a condition that is still true, and a dismiss button on it would
/// only offer to stop mentioning it — which is the state the app was already in.
struct OutOfStepInstancesBanner: View {
    let names: [String]

    /// Says "no longer matches" rather than "is older", deliberately.
    ///
    /// `InstanceFreshness` refuses to claim a direction — reinstalling an earlier Claude
    /// leaves the clone the newer of the two, and calling that "older" is simply wrong while
    /// the remedy is identical either way. The banner is not entitled to assert something
    /// the model declined to determine.
    private var text: String {
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) no longer matches the installed Claude. Clones do not update themselves."
            : "\(list) no longer match the installed Claude. Clones do not update themselves."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color(Ink.warn))
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                // The command rather than a button: refreshing replaces a signed bundle and
                // refuses while the instance is running, and a click that silently fails
                // half the time is worse than a line of text that always works.
                Text("./scripts/refresh-instance.sh --all")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(Ink.warn).opacity(0.12)))
    }
}

struct MigrationBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(Ink.warn))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(Ink.warn).opacity(0.12)))
    }
}
