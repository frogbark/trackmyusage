import SwiftUI
import TMUKit

@main
struct TrackMyUsageApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        // The menu bar is the product's resting state: usage for every account visible
        // without opening anything.
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(
                    systemName: store.summary.isCritical
                        ? "exclamationmark.triangle.fill" : "gauge.medium")
                Text(store.summary.title)
            }
        }
        .menuBarExtraStyle(.window)

        Window("TrackMyUsage", id: "main") {
            InstancesView(store: store)
        }
        .defaultSize(width: 560, height: 420)
    }
}

// MARK: - Menu bar content

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.rows.isEmpty {
                Text("No usage history yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.rows) { row in
                    AccountRow(row: row, isActive: row.name == store.activeInstance) {
                        store.activate(row.instance)
                    }
                }
            }

            if let advice = store.advice, advice.urgency != .none {
                Divider()
                AdviceBanner(advice: advice, store: store)
            }

            Divider()
            HStack {
                Button("Instances…") { openWindow(id: "main") }
                Spacer()
                Button("Refresh") { store.refresh() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 330)
        .task { store.requestNotificationPermission() }
    }
}

struct AccountRow: View {
    let row: UsageStore.Row
    let isActive: Bool
    let activate: () -> Void

    private var value: Double { row.binding?.value ?? 0 }

    private var tint: Color {
        switch value {
        case 100...: return .red
        case 80...: return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.name).fontWeight(.medium)
                if isActive {
                    Text("active")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(Int(value))%").monospacedDigit().foregroundStyle(tint)
            }

            ProgressView(value: min(value, 100), total: 100)
                .tint(tint)

            HStack {
                Text(row.binding?.metric.displayName ?? "—")
                Spacer()
                // Only claim a forecast when one was actually measurable — a blank is
                // honest, an invented "0/h" is not.
                if let f = row.forecast, let at = f.exhaustionDate {
                    Text("full \(at, format: .relative(presentation: .numeric))")
                } else if value >= 100 {
                    Text("exhausted")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
    }
}

struct AdviceBanner: View {
    let advice: SteeringAdvice
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: advice.urgency == .exhausted
                    ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(advice.urgency == .exhausted ? .red : .orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(advice.reason).font(.callout).fixedSize(horizontal: false, vertical: true)

                // Switching is offered, never performed unprompted: rearranging someone's
                // windows mid-task is how a helpful tool becomes an annoying one.
                if let target = advice.recommended,
                    let row = store.rows.first(where: { $0.name == target })
                {
                    Button("Switch to \(target)") { store.activate(row.instance) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}
