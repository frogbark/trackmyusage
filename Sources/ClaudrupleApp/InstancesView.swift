import ClaudrupleKit
import SwiftUI

/// The main window: every instance, what it holds, and what it is using.
struct InstancesView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            if store.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No instances found").font(.headline)
                    Text(
                        "Create one with `claudruple`, or check that Claude Desktop is "
                            + "installed at /Applications/Claude.app."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.rows) { row in
                    InstanceCard(row: row, isActive: row.name == store.activeInstance) {
                        store.activate(row.instance)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Updated every \(Int(UsageStore.pollInterval))s")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Notify me", isOn: $store.notificationsEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Button("Refresh") { store.refresh() }
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

struct InstanceCard: View {
    let row: UsageStore.Row
    let isActive: Bool
    let activate: () -> Void

    private var extensionCount: Int? {
        try? ProfileReader.read(name: row.name, profileURL: row.instance.profileURL)
            .extensions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: row.instance.isPrimary ? "star.fill" : "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(row.name).font(.headline)
                if isActive {
                    Text("active").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button("Open", action: activate).controlSize(.small)
            }

            // Every limit, not just the binding one: a weekly cap creeping up while the
            // 5-hour window looks fine is exactly what a single number would hide.
            if let latest = row.usage.history.samples.last {
                ForEach(
                    latest.metrics.keys.filter { $0.window != nil }
                        .sorted { $0.displayName < $1.displayName }, id: \.self
                ) { metric in
                    let value = latest.metrics[metric] ?? 0
                    HStack(spacing: 8) {
                        Text(metric.displayName)
                            .font(.caption).frame(width: 110, alignment: .leading)
                        ProgressView(value: min(value, 100), total: 100)
                            .tint(value >= 100 ? .red : value >= 80 ? .orange : .accentColor)
                        Text("\(Int(value))%")
                            .font(.caption).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 12) {
                if let n = extensionCount {
                    Label("\(n)", systemImage: "puzzlepiece.extension")
                }
                Label(row.instance.bundleID, systemImage: "number")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
