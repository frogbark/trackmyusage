import SwiftUI
import TMUWidgets
import WidgetKit

// Not named main.swift, deliberately: `@main` and a file called main.swift are top-level-code
// conflicts, and the error names neither cause. The whole extension is this file plus the
// views it borrows from TMUWidgets.

struct SkeletonEntry: TimelineEntry {
    let date: Date
    let text: String
}

struct SkeletonProvider: TimelineProvider {
    func placeholder(in context: Context) -> SkeletonEntry {
        SkeletonEntry(date: Date(), text: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (SkeletonEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SkeletonEntry>) -> Void) {
        // Reads the container so the skeleton proves the entitlement handshake end to end,
        // rather than proving only that a bundle loads.
        let text =
            SharedContainer.groupIdentifier().map { _ in
                SharedContainer.url() == nil ? "no container" : "container ok"
            } ?? "no group"
        completion(Timeline(entries: [SkeletonEntry(date: Date(), text: text)], policy: .never))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "usage", provider: SkeletonProvider()) { entry in
            Text(entry.text)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Your provider usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main struct TMUWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
